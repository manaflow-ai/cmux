import CmuxControlSocket
import CmuxSimulator
import CmuxSimulatorUI
import Foundation

/// Executes serialized UI automation against one Simulator pane coordinator.
@MainActor
public struct SimulatorUIAutomationExecutor {
    /// Minimum accessibility-settle interval after an input mutation.
    public static let postMutationAccessibilityQuiescenceMilliseconds = 750
    private static let accessibilityCaptureTimeoutMilliseconds: Int64 = 30_000

    private let scheduler: any SimulatorUIAutomationScheduling

    /// Creates an executor with an injectable event scheduler for deterministic tests.
    public init(
        scheduler: any SimulatorUIAutomationScheduling =
            ContinuousSimulatorUIAutomationScheduler()
    ) {
        self.scheduler = scheduler
    }

    /// Executes one validated control-socket operation against a pane.
    public func perform(
        _ operation: ControlSimulatorOperation,
        coordinator: SimulatorPaneCoordinator
    ) async throws -> JSONValue {
        switch operation {
        case let .uiSnapshot(sinceScreenHash):
            return try await withSimulatorUIAutomationTransaction(
                coordinator: coordinator
            ) {
                let publishedMutationGeneration =
                    coordinator.uiAutomationMutationGeneration
                let previousRecord = try? coordinator.currentUIAutomationSnapshot(
                    nowMilliseconds: simulatorUIWallTimeNowMilliseconds()
                )
                let record = try await captureSimulatorUIAutomationSnapshot(
                    coordinator: coordinator,
                    retryingUntil: simulatorUIMonotonicNowMilliseconds() + 2_500
                )
                if sinceScreenHash == record.snapshot.screenHash,
                   let previousRecord,
                   let preservedRecord = reusablePublishedSnapshot(
                       previousRecord,
                       after: record,
                       mutationGeneration: publishedMutationGeneration,
                       coordinator: coordinator
                   ) {
                    coordinator.restoreUIAutomationSnapshot(preservedRecord)
                    return simulatorUIUnchangedPayload(preservedRecord.snapshot)
                }
                return simulatorUISnapshotPayload(record.snapshot)
            }
        case let .uiWait(wait):
            return try await withSimulatorUIAutomationTransaction(
                coordinator: coordinator
            ) {
                try await waitForSimulatorUI(wait, coordinator: coordinator)
            }
        case let .uiAction(action):
            return try await withSimulatorUIAutomationTransaction(
                coordinator: coordinator
            ) {
                do {
                    return try await performSimulatorUIAction(
                        action,
                        coordinator: coordinator
                    )
                } catch let failure as SimulatorUIAutomationFailure {
                    throw failure
                } catch let failure as SimulatorFailure {
                    throw simulatorUIActionFailure(failure.message)
                }
            }
        case let .accessibilityTap(label, identifier, role):
            return try await withSimulatorUIAutomationTransaction(
                coordinator: coordinator
            ) {
                do {
                    return try await performSimulatorAccessibilityTap(
                        label: label,
                        identifier: identifier,
                        role: role,
                        coordinator: coordinator
                    )
                } catch let failure as SimulatorUIAutomationFailure {
                    throw failure
                } catch let failure as SimulatorFailure {
                    throw simulatorUIActionFailure(failure.message)
                }
            }
        default:
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.uiOperationInvalid",
                defaultValue: "The Simulator UI automation operation is invalid"
            ))
        }
    }

    private func withSimulatorUIAutomationTransaction<Value>(
        coordinator: SimulatorPaneCoordinator,
        operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        do {
            return try await coordinator.withUIAutomationTransaction(operation)
        } catch SimulatorUIAutomationTransactionError.busy {
            throw SimulatorUIAutomationFailure(
                code: "ui_automation_busy",
                message: String(
                    localized: "cli.simulator.error.uiAutomationBusy",
                    defaultValue: "The Simulator UI automation queue is at capacity"
                ),
                recoveryHint: String(
                    localized: "cli.simulator.recovery.retryAfterActiveOperation",
                    defaultValue: "Retry after the active Simulator UI operation finishes"
                )
            )
        }
    }

    private func performSimulatorAccessibilityTap(
        label: String?,
        identifier: String?,
        role: String?,
        coordinator: SimulatorPaneCoordinator
    ) async throws -> JSONValue {
        try requireSimulatorCapability(.accessibility, coordinator: coordinator)
        try requireSimulatorCapability(.touch, coordinator: coordinator)
        let initial = try await captureSimulatorUIAutomationSnapshot(
            coordinator: coordinator,
            retryingUntil: simulatorUIMonotonicNowMilliseconds() + 2_500
        )
        try requireCompleteSimulatorUISnapshot(initial)
        let refreshed = try await captureSimulatorUIAutomationSnapshot(
            coordinator: coordinator,
            retryingUntil: simulatorUIMonotonicNowMilliseconds() + 2_500
        )
        try requireCompleteSimulatorUISnapshot(refreshed)
        guard refreshed.snapshot.screenHash == initial.snapshot.screenHash else {
            throw simulatorUIStateChangedFailure()
        }
        let targets = refreshed.accessibilityInteractionTargets(
            label: label,
            identifier: identifier,
            role: role
        )
        guard !targets.isEmpty else {
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.tapTargetNotFound",
                defaultValue: "No visible enabled Simulator element matched the accessibility selector"
            ))
        }
        guard targets.count == 1, let target = targets.first else {
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.tapTargetAmbiguous",
                defaultValue: "Multiple visible Simulator elements matched; add --identifier or --role"
            ))
        }
        try await performSimulatorUITap(
            target,
            snapshotDisplay: refreshed.display,
            coordinator: coordinator
        )
        return .object([
            "completed": .bool(true),
            "event_count": .int(2),
            "target": .object([
                "identifier": target.node.identifier.map(JSONValue.string) ?? .null,
                "label": target.node.label.map(JSONValue.string) ?? .null,
                "role": target.node.role.map(JSONValue.string) ?? .null,
                "x": .double(target.activationPoint.x),
                "y": .double(target.activationPoint.y),
            ]),
        ])
    }

    private func performSimulatorUIAction(
        _ action: ControlSimulatorUIAction,
        coordinator: SimulatorPaneCoordinator
    ) async throws -> JSONValue {
        let releasesHeldTouch = if case let .touch(elementRef, down, up, _) = action {
            !down && up
                && coordinator.heldUIAutomationTouch(elementRef: elementRef) != nil
        } else {
            false
        }
        if simulatorUIActionUsesPointerInput(action),
           !coordinator.admitsSimulatorPointerInput(
               releasingHeldUIAutomationTouch: releasesHeldTouch
           ) {
            throw simulatorUITouchAlreadyHeldFailure()
        }
        let preflight = try await preflightSimulatorUIAction(
            action,
            coordinator: coordinator
        )
        let previousScreenHash = preflight.previousScreenHash
        let actionPayload: [String: JSONValue]
        var postActionSettleDelayMilliseconds = 0
        var actionCommitWarning: JSONValue?
        var actionCompleted = true
        switch action {
        case let .tap(elementRef, _, postDelayMilliseconds):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            let record = try simulatorUIActionSourceRecord(preflight)
            let target = try resolveSimulatorUIElement(
                ref: elementRef,
                requiredActions: [.tap],
                record: record
            )
            try await performSimulatorUITap(
                target,
                snapshotDisplay: record.display,
                coordinator: coordinator
            )
            postActionSettleDelayMilliseconds = max(
                postDelayMilliseconds,
                Self.postMutationAccessibilityQuiescenceMilliseconds
            )
            actionPayload = [
                "type": .string("tap"),
                "element_ref": .string(elementRef),
                "x": .double(target.activationPoint.x),
                "y": .double(target.activationPoint.y),
            ]
        case let .touch(elementRef, down, up, delayMilliseconds):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            if coordinator.hasHeldUIAutomationTouch,
               down || (!down && up && coordinator.heldUIAutomationTouch(
                   elementRef: elementRef
               ) == nil) {
                throw simulatorUITouchAlreadyHeldFailure()
            }
            let point: SimulatorPoint
            let snapshotDisplay: SimulatorDisplayMetadata?
            if !down, up,
               let heldTouch = coordinator.heldUIAutomationTouch(
                   elementRef: elementRef
               ) {
                point = heldTouch.point
                snapshotDisplay = heldTouch.display
            } else {
                let record = try simulatorUIActionSourceRecord(preflight)
                let target = try resolveSimulatorUIElement(
                    ref: elementRef,
                    requiredActions: [.touch],
                    record: record
                )
                point = target.activationPoint
                snapshotDisplay = record.display
            }
            let events: [SimulatorPointerEvent]
            do {
                events = try simulatorUITouchEvents(
                    point: point,
                    down: down,
                    up: up,
                    snapshotDisplay: snapshotDisplay,
                    coordinator: coordinator
                )
            } catch {
                if !down, up,
                   coordinator.heldUIAutomationTouch(elementRef: elementRef) != nil {
                    coordinator.releaseInputs()
                    coordinator.releaseHeldUIAutomationTouch(elementRef: elementRef)
                }
                throw error
            }
            _ = try await coordinator.perform(.interactive(.touch(
                events: events,
                holdMilliseconds: delayMilliseconds
            )))
            if down, !up {
                coordinator.holdUIAutomationTouch(
                    elementRef: elementRef,
                    point: point,
                    display: snapshotDisplay
                )
            } else if up {
                if !down {
                    coordinator.releaseHeldUIAutomationTouch(elementRef: elementRef)
                }
                postActionSettleDelayMilliseconds =
                    Self.postMutationAccessibilityQuiescenceMilliseconds
            }
            actionPayload = [
                "type": .string("touch"),
                "element_ref": .string(elementRef),
                "down": .bool(down),
                "up": .bool(up),
                "x": .double(point.x),
                "y": .double(point.y),
            ]
        case let .swipe(
            elementRef, rawDirection, durationMilliseconds, distance, steps,
            _, postDelayMilliseconds
        ):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            let record = try simulatorUIActionSourceRecord(preflight)
            let target = try resolveSimulatorUIElement(
                ref: elementRef,
                requiredActions: [.swipeWithin],
                record: record
            )
            let direction = try simulatorUIDirection(rawDirection)
            guard let points = record.swipePoints(
                elementRef: elementRef,
                direction: direction,
                distance: distance
            ) else {
                throw simulatorUITargetNotActionable(elementRef)
            }
            try await performSimulatorUITimedGesture(
                points: points,
                edge: .none,
                steps: steps,
                durationMilliseconds: durationMilliseconds,
                snapshotDisplay: record.display,
                coordinator: coordinator
            )
            postActionSettleDelayMilliseconds = max(
                postDelayMilliseconds,
                Self.postMutationAccessibilityQuiescenceMilliseconds
            )
            actionPayload = simulatorUIGestureActionPayload(
                type: "swipe",
                elementRef: elementRef,
                direction: direction,
                points: points,
                durationMilliseconds: durationMilliseconds,
                target: target
            )
        case let .drag(
            elementRef, rawDirection, durationMilliseconds, distance, steps,
            _, postDelayMilliseconds
        ):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            let record = try simulatorUIActionSourceRecord(preflight)
            let target = try resolveSimulatorUIElement(
                ref: elementRef,
                requiredActions: [.touch, .swipeWithin],
                record: record
            )
            let direction = try simulatorUIDirection(rawDirection)
            guard let points = record.dragPoints(
                elementRef: elementRef,
                direction: direction,
                distance: distance
            ) else {
                throw simulatorUITargetNotActionable(elementRef)
            }
            try await performSimulatorUITimedGesture(
                points: points,
                edge: .none,
                steps: steps,
                durationMilliseconds: durationMilliseconds,
                snapshotDisplay: record.display,
                coordinator: coordinator
            )
            postActionSettleDelayMilliseconds = max(
                postDelayMilliseconds,
                Self.postMutationAccessibilityQuiescenceMilliseconds
            )
            actionPayload = simulatorUIGestureActionPayload(
                type: "drag",
                elementRef: elementRef,
                direction: direction,
                points: points,
                durationMilliseconds: durationMilliseconds,
                target: target
            )
        case let .longPress(elementRef, durationMilliseconds):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            let record = try simulatorUIActionSourceRecord(preflight)
            let target = try resolveSimulatorUIElement(
                ref: elementRef,
                requiredActions: [.longPress],
                record: record
            )
            let events = try simulatorUITouchEvents(
                point: target.activationPoint,
                down: true,
                up: true,
                snapshotDisplay: record.display,
                coordinator: coordinator
            )
            _ = try await coordinator.perform(.interactive(.touch(
                events: events,
                holdMilliseconds: durationMilliseconds
            )))
            postActionSettleDelayMilliseconds =
                Self.postMutationAccessibilityQuiescenceMilliseconds
            actionPayload = [
                "type": .string("long-press"),
                "element_ref": .string(elementRef),
                "duration_milliseconds": .int(Int64(durationMilliseconds)),
                "x": .double(target.activationPoint.x),
                "y": .double(target.activationPoint.y),
            ]
        case let .typeText(elementRef, text, replaceExisting):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            try requireSimulatorCapability(.keyboard, coordinator: coordinator)
            let record = try simulatorUIActionSourceRecord(preflight)
            let target = try resolveSimulatorUIElement(
                ref: elementRef,
                requiredActions: [.typeText],
                record: record
            )
            guard let focusSelector = record.stableInputSelector(for: elementRef) else {
                throw simulatorUIReferenceFailure(
                    SimulatorUIAutomationReferenceError.stableSelectorUnavailable(
                        elementRef
                    )
                )
            }
            guard record.matching(focusSelector).count == 1 else {
                throw simulatorUIReferenceFailure(
                    SimulatorUIAutomationReferenceError.stableSelectorAmbiguous(
                        elementRef
                    )
                )
            }
            let sequence: SimulatorTextInputSequence
            do {
                sequence = try SimulatorUSKeyboardTextEncoder().encode(text)
            } catch {
                throw invalidSimulatorOperation(String(
                    localized: "cli.simulator.error.uiTextUnsupported",
                    defaultValue: "The text cannot be encoded by Simulator's US keyboard input"
                ))
            }
            try await performSimulatorUITap(
                target,
                snapshotDisplay: record.display,
                coordinator: coordinator
            )
            var textCommitted = false
            do {
                try await simulatorUIDelay(
                    Self.postMutationAccessibilityQuiescenceMilliseconds
                )
                try await waitForSimulatorUITextFocus(
                    selector: focusSelector,
                    elementRef: elementRef,
                    coordinator: coordinator
                )
                if replaceExisting {
                    _ = try await coordinator.perform(.interactive(.keyChord(
                        modifiers: [0xE3],
                        key: 0x04
                    )))
                }
                _ = try await coordinator.perform(.interactive(.typeText(sequence)))
                textCommitted = true
            } catch {
                actionCommitWarning = simulatorUICommittedActionError(error)
                actionCompleted = false
            }
            postActionSettleDelayMilliseconds =
                Self.postMutationAccessibilityQuiescenceMilliseconds
            actionPayload = [
                "type": .string("type-text"),
                "element_ref": .string(elementRef),
                "text_length": .int(Int64(text.count)),
                "replace_existing": .bool(replaceExisting),
                "text_committed": .bool(textCommitted),
            ]
        case let .keyPress(keyCode, durationMilliseconds):
            try requireSimulatorCapability(.keyboard, coordinator: coordinator)
            _ = try await coordinator.perform(.interactive(.keyPresses(
                usages: [keyCode],
                pressDurationMilliseconds: durationMilliseconds,
                interKeyDelayMilliseconds: 0
            )))
            postActionSettleDelayMilliseconds =
                Self.postMutationAccessibilityQuiescenceMilliseconds
            actionPayload = [
                "type": .string("key-press"),
                "key_code": .int(Int64(keyCode)),
                "duration_milliseconds": .int(Int64(durationMilliseconds)),
            ]
        case let .keySequence(keyCodes, delayMilliseconds):
            try requireSimulatorCapability(.keyboard, coordinator: coordinator)
            _ = try await coordinator.perform(.interactive(.keyPresses(
                usages: keyCodes,
                pressDurationMilliseconds: 50,
                interKeyDelayMilliseconds: delayMilliseconds
            )))
            postActionSettleDelayMilliseconds =
                Self.postMutationAccessibilityQuiescenceMilliseconds
            actionPayload = [
                "type": .string("key-sequence"),
                "key_codes": .array(keyCodes.map { .int(Int64($0)) }),
                "delay_milliseconds": .int(Int64(delayMilliseconds)),
            ]
        case let .button(rawButton, durationMilliseconds):
            try requireSimulatorCapability(.hardwareButtons, coordinator: coordinator)
            guard let button = SimulatorHardwareButton(rawValue: rawButton) else {
                throw invalidSimulatorOperation(String.localizedStringWithFormat(
                    String(
                        localized: "cli.simulator.error.unknownButton",
                        defaultValue: "Unknown Simulator hardware button: %@"
                    ),
                    rawButton
                ))
            }
            if let durationMilliseconds {
                _ = try await coordinator.perform(.interactive(.hardwareButtonHold(
                    button,
                    durationMilliseconds: durationMilliseconds
                )))
            } else {
                _ = try await coordinator.perform(.interactive(.hardwareButton(button)))
            }
            actionPayload = [
                "type": .string("button"),
                "button": .string(button.rawValue),
                "duration_milliseconds": durationMilliseconds.map {
                    .int(Int64($0))
                } ?? .null,
            ]
            postActionSettleDelayMilliseconds =
                Self.postMutationAccessibilityQuiescenceMilliseconds
        case let .gesturePreset(
            preset, durationMilliseconds, distance, steps,
            _, postDelayMilliseconds
        ):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            let (points, edge) = try simulatorUIGesturePreset(
                preset,
                distance: distance
            )
            let snapshotDisplay = coordinator.display
            try await performSimulatorUITimedGesture(
                points: points,
                edge: edge,
                steps: steps,
                durationMilliseconds: durationMilliseconds,
                snapshotDisplay: snapshotDisplay,
                coordinator: coordinator
            )
            postActionSettleDelayMilliseconds = max(
                postDelayMilliseconds,
                Self.postMutationAccessibilityQuiescenceMilliseconds
            )
            actionPayload = [
                "type": .string("gesture"),
                "gesture": .string(preset),
                "from": simulatorUIPointPayload(points.from),
                "to": simulatorUIPointPayload(points.to),
                "duration_milliseconds": .int(Int64(durationMilliseconds)),
            ]
        case let .batch(steps):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            let record = try simulatorUIActionSourceRecord(preflight)
            let targets = try steps.map { step in
                (
                    step,
                    try resolveSimulatorUIElement(
                        ref: step.elementRef,
                        requiredActions: [.tap],
                        record: record
                    )
                )
            }
            var completedStepCount = 0
            for (step, target) in targets {
                do {
                    try await simulatorUIDelay(step.preDelayMilliseconds)
                    try await revalidateSimulatorUIRecord(
                        record,
                        elementRef: step.elementRef,
                        coordinator: coordinator
                    )
                    try await performSimulatorUITap(
                        target,
                        snapshotDisplay: record.display,
                        coordinator: coordinator
                    )
                    completedStepCount += 1
                    try await simulatorUIDelay(max(
                        step.postDelayMilliseconds,
                        Self.postMutationAccessibilityQuiescenceMilliseconds
                    ))
                } catch {
                    guard completedStepCount > 0 else { throw error }
                    actionCommitWarning = simulatorUICommittedActionError(error)
                    actionCompleted = false
                    break
                }
            }
            actionPayload = [
                "type": .string("batch"),
                "step_count": .int(Int64(steps.count)),
                "completed_step_count": .int(Int64(completedStepCount)),
            ]
        }

        coordinator.clearUIAutomationSnapshot()
        var result: [String: JSONValue] = [
            "completed": .bool(actionCompleted),
            "action": .object(actionPayload),
        ]
        if let actionCommitWarning {
            result["snapshot_warning"] = .string(simulatorUIActionCommittedWarning())
            result["ui_error"] = actionCommitWarning
            return .object(result)
        }
        do {
            try await simulatorUIDelay(postActionSettleDelayMilliseconds)
            let refreshed = try await captureSettledSimulatorUISnapshot(
                coordinator: coordinator
            )
            result["capture"] = simulatorUISnapshotPayload(refreshed.snapshot)
            result["previous_screen_hash"] = previousScreenHash
                .map(JSONValue.string) ?? .null
            result["screen_changed"] = previousScreenHash.map {
                .bool($0 != refreshed.snapshot.screenHash)
            } ?? .null
        } catch let failure as SimulatorUIAutomationFailure {
            coordinator.clearUIAutomationSnapshot()
            result["snapshot_warning"] = .string(simulatorUIActionCommittedWarning())
            result["ui_error"] = failure.uiError
        } catch {
            coordinator.clearUIAutomationSnapshot()
            result["snapshot_warning"] = .string(simulatorUIActionCommittedWarning())
            result["ui_error"] = simulatorUISnapshotCaptureFailure(
                String(
                    localized: "cli.simulator.error.uiSnapshotViewportMissing",
                    defaultValue: "The Simulator UI snapshot has no usable foreground viewport"
                )
            ).uiError
        }
        return .object(result)
    }

    private func preflightSimulatorUIAction(
        _ action: ControlSimulatorUIAction,
        coordinator: SimulatorPaneCoordinator
    ) async throws -> SimulatorUIAutomationActionPreflight {
        try await simulatorUIDelay(simulatorUIPreActionDelayMilliseconds(action))
        if case let .touch(elementRef, down, up, _) = action,
           !down, up,
           coordinator.heldUIAutomationTouch(elementRef: elementRef) != nil {
            return SimulatorUIAutomationActionPreflight(
                sourceRecord: nil,
                previousScreenHash: try? coordinator.currentUIAutomationSnapshot(
                    nowMilliseconds: simulatorUIWallTimeNowMilliseconds()
                ).snapshot.screenHash
            )
        }
        let elementRefs = simulatorUIElementRefs(in: action)
        guard !elementRefs.isEmpty else {
            return SimulatorUIAutomationActionPreflight(
                sourceRecord: nil,
                previousScreenHash: try? coordinator.currentUIAutomationSnapshot(
                    nowMilliseconds: simulatorUIWallTimeNowMilliseconds()
                ).snapshot.screenHash
            )
        }

        let current = try currentSimulatorUISnapshot(coordinator: coordinator)
        for elementRef in elementRefs where current.element(ref: elementRef) == nil {
            throw simulatorUIReferenceFailure(
                SimulatorUIAutomationReferenceError.elementRefNotFound(elementRef)
            )
        }
        if case .batch = action {
            return SimulatorUIAutomationActionPreflight(
                sourceRecord: current,
                previousScreenHash: current.snapshot.screenHash
            )
        }
        try await revalidateSimulatorUIRecord(
            current,
            elementRef: elementRefs.first,
            coordinator: coordinator
        )
        return SimulatorUIAutomationActionPreflight(
            sourceRecord: current,
            previousScreenHash: current.snapshot.screenHash
        )
    }

    private func revalidateSimulatorUIRecord(
        _ sourceRecord: SimulatorUIAutomationSnapshotRecord,
        elementRef: String?,
        coordinator: SimulatorPaneCoordinator
    ) async throws {
        let refreshed = try await captureSimulatorUIAutomationSnapshot(
            coordinator: coordinator,
            retryingUntil: simulatorUIMonotonicNowMilliseconds() + 2_500
        )
        guard refreshed.snapshot.screenHash == sourceRecord.snapshot.screenHash else {
            throw simulatorUIStateChangedFailure(elementRef: elementRef)
        }
    }

    private func simulatorUIPreActionDelayMilliseconds(
        _ action: ControlSimulatorUIAction
    ) -> Int {
        switch action {
        case let .tap(_, preDelayMilliseconds, _),
             let .swipe(_, _, _, _, _, preDelayMilliseconds, _),
             let .drag(_, _, _, _, _, preDelayMilliseconds, _),
             let .gesturePreset(_, _, _, _, preDelayMilliseconds, _):
            return preDelayMilliseconds
        case .touch, .longPress, .typeText, .keyPress, .keySequence, .button, .batch:
            return 0
        }
    }

    private func simulatorUIActionSourceRecord(
        _ preflight: SimulatorUIAutomationActionPreflight
    ) throws -> SimulatorUIAutomationSnapshotRecord {
        guard let sourceRecord = preflight.sourceRecord else {
            throw simulatorUIReferenceFailure(
                SimulatorUIAutomationReferenceError.snapshotMissing
            )
        }
        return sourceRecord
    }

    private func simulatorUIElementRefs(
        in action: ControlSimulatorUIAction
    ) -> [String] {
        switch action {
        case let .tap(elementRef, _, _),
             let .touch(elementRef, _, _, _),
             let .swipe(elementRef, _, _, _, _, _, _),
             let .drag(elementRef, _, _, _, _, _, _),
             let .longPress(elementRef, _),
             let .typeText(elementRef, _, _):
            return [elementRef]
        case let .batch(steps):
            return steps.map(\.elementRef)
        case .keyPress, .keySequence, .button, .gesturePreset:
            return []
        }
    }

    private func simulatorUIActionUsesPointerInput(
        _ action: ControlSimulatorUIAction
    ) -> Bool {
        switch action {
        case .tap, .touch, .swipe, .drag, .longPress, .typeText,
             .gesturePreset, .batch:
            true
        case .keyPress, .keySequence, .button:
            false
        }
    }

    private func waitForSimulatorUI(
        _ wait: ControlSimulatorUIWait,
        coordinator: SimulatorPaneCoordinator
    ) async throws -> JSONValue {
        try requireSimulatorCapability(.accessibility, coordinator: coordinator)
        let startedAt = simulatorUIMonotonicNowMilliseconds()
        let deadline = startedAt + Int64(wait.timeoutMilliseconds)
        // Zero means one current sample rather than no samples. Keep that
        // sample's worker response bounded by the standard capture timeout.
        let captureDeadline = wait.timeoutMilliseconds == 0
            ? startedAt + Self.accessibilityCaptureTimeoutMilliseconds
            : deadline
        let selector: SimulatorUIAutomationSelector?
        if let elementRef = wait.elementRef {
            do {
                selector = try coordinator.stableUIAutomationSelector(
                    ref: elementRef,
                    nowMilliseconds: simulatorUIWallTimeNowMilliseconds()
                )
            } catch {
                throw simulatorUIReferenceFailure(error)
            }
        } else {
            selector = SimulatorUIAutomationSelector(
                identifier: wait.identifier,
                label: wait.label,
                role: try wait.role.map(simulatorUIRole),
                value: wait.value
            )
        }

        let publishedMutationGeneration = coordinator.uiAutomationMutationGeneration
        var preservedRecord = try? coordinator.currentUIAutomationSnapshot(
            nowMilliseconds: simulatorUIWallTimeNowMilliseconds()
        )
        var stableHash: String?
        var stableSince: Int64?
        var latestRecord: SimulatorUIAutomationSnapshotRecord?
        // CoreSimulator's accessibility translator exposes snapshots but no
        // change notification, so a cancellation-aware scheduler owns the
        // bounded sampling events.
        let events = SimulatorUIAutomationTickSequence(
            scheduler: scheduler,
            intervalMilliseconds: Int64(wait.pollIntervalMilliseconds),
            deadlineMilliseconds: deadline
        )
        for try await _ in events {
            let capturedRecord: SimulatorUIAutomationSnapshotRecord
            do {
                capturedRecord = try await captureSimulatorUIAutomationSnapshot(
                    coordinator: coordinator,
                    retryingUntil: captureDeadline,
                    retryingUIStateChanges: true,
                    propagatingDeadlineExceeded: true
                )
            } catch is SimulatorUIAutomationCaptureDeadlineExceeded {
                break
            }
            let record: SimulatorUIAutomationSnapshotRecord
            if let preservedRecord,
               let reusableRecord = reusablePublishedSnapshot(
                   preservedRecord,
                   after: capturedRecord,
                   mutationGeneration: publishedMutationGeneration,
                   coordinator: coordinator
               ) {
                record = reusableRecord
                coordinator.restoreUIAutomationSnapshot(record)
            } else {
                preservedRecord = nil
                record = capturedRecord
            }
            latestRecord = record
            let now = simulatorUIMonotonicNowMilliseconds()
            let matches = try simulatorUIWaitMatches(
                wait,
                selector: selector,
                record: record,
                nowMilliseconds: now,
                stableHash: &stableHash,
                stableSince: &stableSince
            )
            if matches.didMatch {
                return .object([
                    "completed": .bool(true),
                    "predicate": .string(wait.predicate),
                    "capture": simulatorUISnapshotPayload(record.snapshot),
                    "matches": .array(matches.elements.map(simulatorUIElementPayload)),
                ])
            }
        }

        let candidates = latestRecord.map {
            simulatorUIWaitCandidates(wait, selector: selector, record: $0)
        } ?? []
        throw SimulatorUIAutomationFailure(
            code: "wait_timeout",
            message: String.localizedStringWithFormat(
                String(
                    localized: "cli.simulator.error.uiWaitTimeout",
                    defaultValue: "Timed out after %lld ms waiting for '%@' (%lld candidate(s))"
                ),
                Int64(wait.timeoutMilliseconds),
                wait.predicate,
                Int64(candidates.count)
            ),
            recoveryHint: simulatorUIWaitRecoveryHint(),
            candidates: simulatorUICompactCandidatePayloads(candidates),
            timeoutMilliseconds: wait.timeoutMilliseconds
        )
    }

    private func waitForSimulatorUITextFocus(
        selector: SimulatorUIAutomationSelector,
        elementRef: String,
        coordinator: SimulatorPaneCoordinator
    ) async throws {
        let timeoutMilliseconds: Int64 = 2_500
        let deadline = simulatorUIMonotonicNowMilliseconds() + timeoutMilliseconds
        var latestCandidates: [SimulatorUIAutomationElement] = []

        let events = SimulatorUIAutomationTickSequence(
            scheduler: scheduler,
            intervalMilliseconds: 100,
            deadlineMilliseconds: deadline
        )
        for try await _ in events {
            let record = try await captureSimulatorUIAutomationSnapshot(
                coordinator: coordinator,
                retryingUntil: deadline
            )
            latestCandidates = record.matching(selector)
            try requireUniqueSimulatorUIWaitCandidate(latestCandidates)
            if latestCandidates.first?.state.isFocused == true {
                return
            }
            if let candidate = latestCandidates.first,
               candidate.state.isFocused == nil {
                throw SimulatorUIAutomationFailure(
                    code: "target_not_actionable",
                    message: String(
                        localized: "cli.simulator.error.uiFocusUnavailable",
                        defaultValue: "The matched Simulator element does not expose focus state"
                    ),
                    recoveryHint: simulatorUIActionRecoveryHint(),
                    elementRef: elementRef,
                    candidates: [simulatorUIElementPayload(candidate)]
                )
            }
        }

        throw SimulatorUIAutomationFailure(
            code: "target_not_focused",
            message: String.localizedStringWithFormat(
                String(
                    localized: "cli.simulator.error.uiWaitTimeout",
                    defaultValue: "Timed out after %lld ms waiting for '%@' (%lld candidate(s))"
                ),
                timeoutMilliseconds,
                "focused",
                Int64(latestCandidates.count)
            ),
            recoveryHint: simulatorUIActionRecoveryHint(),
            elementRef: elementRef,
            candidates: simulatorUICompactCandidatePayloads(latestCandidates),
            timeoutMilliseconds: Int(timeoutMilliseconds)
        )
    }

    private func reusablePublishedSnapshot(
        _ published: SimulatorUIAutomationSnapshotRecord,
        after captured: SimulatorUIAutomationSnapshotRecord,
        mutationGeneration: UInt64,
        coordinator: SimulatorPaneCoordinator
    ) -> SimulatorUIAutomationSnapshotRecord? {
        guard !published.hasTruncatedVisibleText,
              !captured.hasTruncatedVisibleText,
              coordinator.uiAutomationMutationGeneration == mutationGeneration,
              simulatorUIWallTimeNowMilliseconds()
                  <= published.snapshot.expiresAtMilliseconds,
              published.snapshot.simulatorID == captured.snapshot.simulatorID,
              published.snapshot.screenHash == captured.snapshot.screenHash else {
            return nil
        }
        return SimulatorUIAutomationSnapshotRecord(
            snapshot: published.snapshot,
            elementRecords: published.elementRecords,
            display: captured.display
        )
    }

    private func simulatorUIWaitMatches(
        _ wait: ControlSimulatorUIWait,
        selector: SimulatorUIAutomationSelector?,
        record: SimulatorUIAutomationSnapshotRecord,
        nowMilliseconds: Int64,
        stableHash: inout String?,
        stableSince: inout Int64?
    ) throws -> (didMatch: Bool, elements: [SimulatorUIAutomationElement]) {
        try requireCompleteSimulatorUISnapshot(record)
        if wait.predicate == "settled" {
            try requireCompleteSimulatorUITextState(record)
            if stableHash != record.snapshot.screenHash {
                stableHash = record.snapshot.screenHash
                stableSince = nowMilliseconds
            }
            return (
                nowMilliseconds - (stableSince ?? nowMilliseconds)
                    >= Int64(wait.settledDurationMilliseconds),
                []
            )
        }

        var candidates = simulatorUIWaitCandidates(
            wait,
            selector: selector,
            record: record
        )
        if let text = wait.text {
            let textMatches = Set(record.containingText(text).map(\.ref))
            candidates = candidates.filter { textMatches.contains($0.ref) }
        }
        if selector?.sourceElementRef != nil {
            try requireUniqueSimulatorUIWaitCandidate(candidates)
        }
        switch wait.predicate {
        case "exists":
            return (!candidates.isEmpty, candidates)
        case "gone":
            if selector?.hasFields != true, candidates.count > 1,
               !record.candidatesShareMatchingText(candidates, containing: wait.text ?? "") {
                throw simulatorUIAmbiguousWaitFailure(candidates)
            }
            if candidates.isEmpty,
               record.truncationCouldHideMatch(
                   selector: selector,
                   containingText: wait.text
               ) {
                throw simulatorUITruncatedSnapshotFailure()
            }
            return (candidates.isEmpty, candidates)
        case "enabled":
            try requireUniqueSimulatorUIWaitCandidate(candidates)
            return (candidates.first?.state.isEnabled == true, candidates)
        case "focused":
            try requireUniqueSimulatorUIWaitCandidate(candidates)
            guard let candidate = candidates.first else { return (false, candidates) }
            guard candidate.state.isFocused != nil else {
                throw SimulatorUIAutomationFailure(
                    code: "target_not_actionable",
                    message: String(
                        localized: "cli.simulator.error.uiFocusUnavailable",
                        defaultValue: "The matched Simulator element does not expose focus state"
                    ),
                    recoveryHint: simulatorUIActionRecoveryHint(),
                    elementRef: candidate.ref,
                    candidates: [simulatorUIElementPayload(candidate)]
                )
            }
            return (candidate.state.isFocused == true, candidates)
        case "text-contains":
            if candidates.count > 1,
               !record.candidatesShareMatchingText(candidates, containing: wait.text ?? "") {
                throw simulatorUIAmbiguousWaitFailure(candidates)
            }
            return (!candidates.isEmpty, candidates)
        default:
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.uiWaitPredicateInvalid",
                defaultValue: "The Simulator UI wait predicate is invalid"
            ))
        }
    }

    private func simulatorUIWaitCandidates(
        _ wait: ControlSimulatorUIWait,
        selector: SimulatorUIAutomationSelector?,
        record: SimulatorUIAutomationSnapshotRecord
    ) -> [SimulatorUIAutomationElement] {
        if let selector, selector.hasFields {
            return record.matching(selector)
        }
        if let text = wait.text {
            return record.containingText(text)
        }
        return []
    }

    private func requireUniqueSimulatorUIWaitCandidate(
        _ candidates: [SimulatorUIAutomationElement]
    ) throws {
        guard candidates.count <= 1 else {
            throw simulatorUIAmbiguousWaitFailure(candidates)
        }
    }

    private func simulatorUIAmbiguousWaitFailure(
        _ candidates: [SimulatorUIAutomationElement]
    ) -> SimulatorUIAutomationFailure {
        SimulatorUIAutomationFailure(
            code: "target_ambiguous",
            message: String(
                localized: "cli.simulator.error.uiWaitTargetAmbiguous",
                defaultValue: "The Simulator UI wait selector matched multiple elements"
            ),
            recoveryHint: simulatorUIWaitRecoveryHint(),
            candidates: simulatorUICompactCandidatePayloads(candidates)
        )
    }

    private func simulatorUICompactCandidatePayloads(
        _ candidates: [SimulatorUIAutomationElement]
    ) -> [JSONValue] {
        candidates.prefix(simulatorUIAutomationMaximumCandidateCount)
            .map(simulatorUIElementPayload)
    }

    private func captureSimulatorUIAutomationSnapshot(
        coordinator: SimulatorPaneCoordinator,
        retryingUntil deadlineMilliseconds: Int64? = nil,
        retryingUIStateChanges: Bool = false,
        propagatingDeadlineExceeded: Bool = false
    ) async throws -> SimulatorUIAutomationSnapshotRecord {
        guard let deadlineMilliseconds else {
            return try await captureSimulatorUIAutomationSnapshotOnce(
                coordinator: coordinator,
                timeout: .milliseconds(Self.accessibilityCaptureTimeoutMilliseconds)
            )
        }
        do {
            return try await SimulatorUIAutomationCaptureRetry(
                scheduler: scheduler
            ).capture(
                until: deadlineMilliseconds,
                retrying: retryingUIStateChanges
                    ? ["snapshot_capture_failed", "ui_state_changed"]
                    : ["snapshot_capture_failed"]
            ) { remaining in
                try await captureSimulatorUIAutomationSnapshotOnce(
                    coordinator: coordinator,
                    timeout: remaining
                )
            }
        } catch let error as SimulatorUIAutomationCaptureDeadlineExceeded {
            if propagatingDeadlineExceeded {
                throw error
            }
            throw simulatorUISnapshotCaptureFailure(String(
                localized: "cli.simulator.error.uiSnapshotDidNotSettle",
                defaultValue: "The refreshed Simulator UI snapshot did not settle"
            ))
        }
    }

    private func captureSimulatorUIAutomationSnapshotOnce(
        coordinator: SimulatorPaneCoordinator,
        timeout: Duration
    ) async throws -> SimulatorUIAutomationSnapshotRecord {
        try requireSimulatorCapability(.accessibility, coordinator: coordinator)
        guard let simulatorID = coordinator.selectedDeviceID else {
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.deviceRequired",
                defaultValue: "The Simulator pane has no selected device"
            ))
        }
        let mutationGeneration = coordinator.uiAutomationMutationGeneration
        let result: SimulatorControlResult
        do {
            result = try await coordinator.readAccessibility(timeout: timeout)
        } catch let failure as SimulatorFailure {
            throw simulatorUISnapshotCaptureFailure(failure.message)
        } catch {
            throw simulatorUISnapshotCaptureFailure(String(
                localized: "cli.simulator.error.accessibilityMissing",
                defaultValue: "The Simulator worker returned no accessibility snapshot"
            ))
        }
        guard coordinator.uiAutomationMutationGeneration == mutationGeneration else {
            throw simulatorUIStateChangedFailure()
        }
        guard case let .accessibility(snapshot) = result else {
            throw simulatorUISnapshotCaptureFailure(String(
                localized: "cli.simulator.error.accessibilityMissing",
                defaultValue: "The Simulator worker returned no accessibility snapshot"
            ))
        }
        guard coordinator.display == snapshot.display else {
            throw simulatorUISnapshotCaptureFailure(simulatorUIDisplayChangedMessage())
        }
        do {
            return try await coordinator.recordUIAutomationSnapshot(
                snapshot,
                simulatorID: simulatorID,
                capturedAtMilliseconds: simulatorUIWallTimeNowMilliseconds(),
                expectedMutationGeneration: mutationGeneration
            )
        } catch SimulatorUIAutomationSnapshotRecordingError.invalidatedDuringPreparation {
            throw simulatorUIStateChangedFailure()
        } catch {
            throw simulatorUISnapshotCaptureFailure(String(
                localized: "cli.simulator.error.uiSnapshotViewportMissing",
                defaultValue: "The Simulator UI snapshot has no usable foreground viewport"
            ))
        }
    }

    private func captureSettledSimulatorUISnapshot(
        coordinator: SimulatorPaneCoordinator
    ) async throws -> SimulatorUIAutomationSnapshotRecord {
        let deadline = simulatorUIMonotonicNowMilliseconds() + 2_500
        var previousHash: String?
        var stableSince: Int64?
        // The accessibility bridge has no event stream. Sampling is bounded,
        // cancellable, and emitted only by the injected scheduler.
        let events = SimulatorUIAutomationTickSequence(
            scheduler: scheduler,
            intervalMilliseconds: 100,
            deadlineMilliseconds: deadline
        )
        for try await _ in events {
            let record = try await captureSimulatorUIAutomationSnapshot(
                coordinator: coordinator,
                retryingUntil: deadline
            )
            let now = simulatorUIMonotonicNowMilliseconds()
            if previousHash == record.snapshot.screenHash {
                if now - (stableSince ?? now) >= 100 {
                    return record
                }
            } else {
                previousHash = record.snapshot.screenHash
                stableSince = now
            }
        }
        throw simulatorUISnapshotCaptureFailure(String(
            localized: "cli.simulator.error.uiSnapshotDidNotSettle",
            defaultValue: "The refreshed Simulator UI snapshot did not settle"
        ))
    }

    private func currentSimulatorUISnapshot(
        coordinator: SimulatorPaneCoordinator
    ) throws -> SimulatorUIAutomationSnapshotRecord {
        do {
            return try coordinator.currentUIAutomationSnapshot(
                nowMilliseconds: simulatorUIWallTimeNowMilliseconds()
            )
        } catch {
            throw simulatorUIReferenceFailure(error)
        }
    }

    private func resolveSimulatorUIElement(
        ref: String,
        requiredActions: [SimulatorUIAutomationActionName],
        record: SimulatorUIAutomationSnapshotRecord
    ) throws -> SimulatorUIAutomationElementRecord {
        guard let element = record.element(ref: ref) else {
            throw simulatorUIReferenceFailure(
                SimulatorUIAutomationReferenceError.elementRefNotFound(ref)
            )
        }
        guard requiredActions.isEmpty
                || requiredActions.contains(where: element.element.actions.contains) else {
            throw simulatorUIReferenceFailure(
                SimulatorUIAutomationReferenceError.targetNotActionable(
                    ref: ref,
                    required: requiredActions
                )
            )
        }
        return element
    }

    private func simulatorUIReferenceFailure(
        _ error: any Error
    ) -> SimulatorUIAutomationFailure {
        guard let referenceError = error as? SimulatorUIAutomationReferenceError else {
            return SimulatorUIAutomationFailure(
                code: "element_ref_not_found",
                message: String(
                    localized: "cli.simulator.error.uiElementRefInvalid",
                    defaultValue: "The Simulator UI element reference is invalid"
                ),
                recoveryHint: simulatorUICaptureRecoveryHint()
            )
        }
        switch referenceError {
        case .snapshotMissing:
            return SimulatorUIAutomationFailure(
                code: "snapshot_missing",
                message: String(
                    localized: "cli.simulator.error.uiSnapshotMissing",
                    defaultValue: "Run 'cmux ios snapshot' before using an element ref"
                ),
                recoveryHint: simulatorUICaptureRecoveryHint()
            )
        case let .snapshotExpired(ageMilliseconds):
            return SimulatorUIAutomationFailure(
                code: "snapshot_expired",
                message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.simulator.error.uiSnapshotExpired",
                        defaultValue: "The Simulator UI snapshot expired after %lld ms; capture it again"
                    ),
                    ageMilliseconds
                ),
                recoveryHint: simulatorUICaptureRecoveryHint(),
                snapshotAgeMilliseconds: ageMilliseconds
            )
        case let .elementRefNotFound(ref):
            return SimulatorUIAutomationFailure(
                code: "element_ref_not_found",
                message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.simulator.error.uiElementRefNotFound",
                        defaultValue: "Element ref '%@' is not in the current Simulator UI snapshot"
                    ),
                    ref
                ),
                recoveryHint: simulatorUICaptureRecoveryHint(),
                elementRef: ref
            )
        case let .targetNotActionable(ref, _):
            return simulatorUITargetNotActionable(ref)
        case let .stableSelectorUnavailable(ref):
            return SimulatorUIAutomationFailure(
                code: "target_not_found",
                message: String.localizedStringWithFormat(
                    String(
                        localized: "cli.simulator.error.uiStableSelectorUnavailable",
                        defaultValue: "Element ref '%@' has no stable fields for a UI wait"
                    ),
                    ref
                ),
                recoveryHint: simulatorUIWaitRecoveryHint(),
                elementRef: ref
            )
        case let .stableSelectorAmbiguous(ref):
            return SimulatorUIAutomationFailure(
                code: "target_ambiguous",
                message: String(
                    localized: "cli.simulator.error.uiWaitTargetAmbiguous",
                    defaultValue: "The Simulator UI wait selector matched multiple elements"
                ),
                recoveryHint: simulatorUIWaitRecoveryHint(),
                elementRef: ref
            )
        }
    }

    private func simulatorUITargetNotActionable(
        _ ref: String
    ) -> SimulatorUIAutomationFailure {
        SimulatorUIAutomationFailure(
            code: "target_not_actionable",
            message: String.localizedStringWithFormat(
                String(
                    localized: "cli.simulator.error.uiTargetNotActionable",
                    defaultValue: "Element ref '%@' does not support the requested action"
                ),
                ref
            ),
            recoveryHint: simulatorUIActionRecoveryHint(),
            elementRef: ref
        )
    }

    private func simulatorUITouchAlreadyHeldFailure() -> SimulatorUIAutomationFailure {
        SimulatorUIAutomationFailure(
            code: "touch_already_held",
            message: String(
                localized: "cli.simulator.error.uiTouchAlreadyHeld",
                defaultValue: "A Simulator touch is already being held"
            ),
            recoveryHint: String(
                localized: "cli.simulator.recovery.releaseHeldTouch",
                defaultValue: "Release the held Simulator touch before starting another"
            )
        )
    }

    private func simulatorUISnapshotCaptureFailure(
        _ message: String
    ) -> SimulatorUIAutomationFailure {
        SimulatorUIAutomationFailure(
            code: "snapshot_capture_failed",
            message: message,
            recoveryHint: simulatorUICaptureRecoveryHint()
        )
    }

    private func requireCompleteSimulatorUISnapshot(
        _ record: SimulatorUIAutomationSnapshotRecord
    ) throws {
        guard !record.snapshot.isTruncated else {
            throw simulatorUITruncatedSnapshotFailure()
        }
    }

    private func requireCompleteSimulatorUITextState(
        _ record: SimulatorUIAutomationSnapshotRecord
    ) throws {
        guard !record.hasTruncatedVisibleText else {
            throw simulatorUITruncatedSnapshotFailure()
        }
    }

    private func simulatorUITruncatedSnapshotFailure() -> SimulatorUIAutomationFailure {
        SimulatorUIAutomationFailure(
            code: "snapshot_truncated",
            message: String(
                localized: "cli.simulator.output.uiSnapshotTruncated",
                defaultValue: "The Simulator UI snapshot reached its element limit"
            ),
            recoveryHint: simulatorUICaptureRecoveryHint()
        )
    }

    private func simulatorUIStateChangedFailure(
        elementRef: String? = nil
    ) -> SimulatorUIAutomationFailure {
        SimulatorUIAutomationFailure(
            code: "ui_state_changed",
            message: String(
                localized: "cli.simulator.error.uiStateChanged",
                defaultValue: "The Simulator UI changed after the element ref was captured"
            ),
            recoveryHint: simulatorUICaptureRecoveryHint(),
            elementRef: elementRef
        )
    }

    private func simulatorUIDisplayChangedMessage() -> String {
        String(
            localized: "cli.simulator.error.uiDisplayChanged",
            defaultValue: "The Simulator display changed while UI state was captured"
        )
    }

    private func simulatorUIActionFailure(
        _ message: String
    ) -> SimulatorUIAutomationFailure {
        SimulatorUIAutomationFailure(
            code: "action_failed",
            message: message,
            recoveryHint: simulatorUIActionRecoveryHint()
        )
    }

    private func simulatorUICommittedActionError(_ error: any Error) -> JSONValue {
        if let failure = error as? SimulatorUIAutomationFailure {
            return failure.uiError
        }
        if let failure = error as? SimulatorFailure {
            return simulatorUIActionFailure(failure.message).uiError
        }
        return SimulatorUIAutomationFailure(
            code: "action_committed",
            message: simulatorUIActionCommittedWarning(),
            recoveryHint: simulatorUICaptureRecoveryHint()
        ).uiError
    }

    private func simulatorUIActionCommittedWarning() -> String {
        String(
            localized: "cli.simulator.warning.uiSnapshotRefreshFailed",
            defaultValue: "The action succeeded, but the refreshed UI snapshot was unavailable"
        )
    }

    private func simulatorUICaptureRecoveryHint() -> String {
        String(
            localized: "cli.simulator.recovery.captureSnapshot",
            defaultValue: "Capture a fresh Simulator UI snapshot and retry"
        )
    }

    private func simulatorUIActionRecoveryHint() -> String {
        String(
            localized: "cli.simulator.recovery.chooseAdvertisedAction",
            defaultValue: "Capture a fresh snapshot and choose an advertised action"
        )
    }

    private func simulatorUIWaitRecoveryHint() -> String {
        String(
            localized: "cli.simulator.recovery.refineWait",
            defaultValue: "Inspect a fresh snapshot, refine the wait target, and retry"
        )
    }

    private func requireSimulatorCapability(
        _ capability: SimulatorCapability,
        coordinator: SimulatorPaneCoordinator
    ) throws {
        guard coordinator.supports(capability) else {
            throw SimulatorFailure(
                code: "simulator_capability_unavailable",
                message: String(
                    localized: "cli.simulator.error.capabilityUnavailable",
                    defaultValue: "The active Simulator worker does not support this operation"
                ),
                isRecoverable: true
            )
        }
    }

    private func performSimulatorUITap(
        _ target: SimulatorUIAutomationElementRecord,
        snapshotDisplay: SimulatorDisplayMetadata?,
        coordinator: SimulatorPaneCoordinator
    ) async throws {
        let events = try simulatorUITouchEvents(
            point: target.activationPoint,
            down: true,
            up: true,
            snapshotDisplay: snapshotDisplay,
            coordinator: coordinator
        )
        _ = try await coordinator.perform(.interactive(.gesture(events)))
    }

    private func simulatorUITouchEvents(
        point: SimulatorPoint,
        down: Bool,
        up: Bool,
        snapshotDisplay: SimulatorDisplayMetadata?,
        coordinator: SimulatorPaneCoordinator
    ) throws -> [SimulatorPointerEvent] {
        var events: [SimulatorPointerEvent] = []
        if down {
            events.append(SimulatorPointerEvent(phase: .began, primary: point))
        }
        if up {
            events.append(SimulatorPointerEvent(phase: .ended, primary: point))
        }
        return try simulatorUIRawPointerEvents(
            events,
            snapshotDisplay: snapshotDisplay,
            coordinator: coordinator
        )
    }

    private func performSimulatorUITimedGesture(
        points: SimulatorUIAutomationGesturePoints,
        edge: SimulatorEdge,
        steps: Int,
        durationMilliseconds: Int,
        snapshotDisplay: SimulatorDisplayMetadata?,
        coordinator: SimulatorPaneCoordinator
    ) async throws {
        let events = (0...steps).map { index in
            let progress = Double(index) / Double(steps)
            let phase: SimulatorTouchPhase = index == 0
                ? .began
                : (index == steps ? .ended : .moved)
            return SimulatorPointerEvent(
                phase: phase,
                primary: SimulatorPoint(
                    x: points.from.x + (points.to.x - points.from.x) * progress,
                    y: points.from.y + (points.to.y - points.from.y) * progress
                ),
                edge: edge
            )
        }
        _ = try await coordinator.perform(.interactive(.timedGesture(
            events: try simulatorUIRawPointerEvents(
                events,
                snapshotDisplay: snapshotDisplay,
                coordinator: coordinator
            ),
            durationMilliseconds: durationMilliseconds
        )))
    }

    private func simulatorUIRawPointerEvents(
        _ events: [SimulatorPointerEvent],
        snapshotDisplay: SimulatorDisplayMetadata?,
        coordinator: SimulatorPaneCoordinator
    ) throws -> [SimulatorPointerEvent] {
        guard coordinator.display == snapshotDisplay else {
            throw simulatorUIStateChangedFailure()
        }
        guard let display = snapshotDisplay else { return events }
        let geometry = SimulatorOrientationGeometry(display: display)
        return events.map(geometry.rawPointerEvent)
    }

    private func simulatorUIGesturePreset(
        _ preset: String,
        distance: Double
    ) throws -> (SimulatorUIAutomationGesturePoints, SimulatorEdge) {
        let lower = 0.5 - distance / 2
        let upper = 0.5 + distance / 2
        switch preset {
        case "scroll-up":
            return (
                SimulatorUIAutomationGesturePoints(
                    from: SimulatorPoint(x: 0.5, y: upper),
                    to: SimulatorPoint(x: 0.5, y: lower)
                ),
                .none
            )
        case "scroll-down":
            return (
                SimulatorUIAutomationGesturePoints(
                    from: SimulatorPoint(x: 0.5, y: lower),
                    to: SimulatorPoint(x: 0.5, y: upper)
                ),
                .none
            )
        case "scroll-left":
            return (
                SimulatorUIAutomationGesturePoints(
                    from: SimulatorPoint(x: upper, y: 0.5),
                    to: SimulatorPoint(x: lower, y: 0.5)
                ),
                .none
            )
        case "scroll-right":
            return (
                SimulatorUIAutomationGesturePoints(
                    from: SimulatorPoint(x: lower, y: 0.5),
                    to: SimulatorPoint(x: upper, y: 0.5)
                ),
                .none
            )
        case "swipe-from-left-edge":
            return (
                SimulatorUIAutomationGesturePoints(
                    from: SimulatorPoint(x: 0.01, y: 0.5),
                    to: SimulatorPoint(x: min(0.99, 0.01 + distance), y: 0.5)
                ),
                .left
            )
        case "swipe-from-right-edge":
            return (
                SimulatorUIAutomationGesturePoints(
                    from: SimulatorPoint(x: 0.99, y: 0.5),
                    to: SimulatorPoint(x: max(0.01, 0.99 - distance), y: 0.5)
                ),
                .right
            )
        case "swipe-from-top-edge":
            return (
                SimulatorUIAutomationGesturePoints(
                    from: SimulatorPoint(x: 0.5, y: 0.01),
                    to: SimulatorPoint(x: 0.5, y: min(0.99, 0.01 + distance))
                ),
                .top
            )
        case "swipe-from-bottom-edge":
            return (
                SimulatorUIAutomationGesturePoints(
                    from: SimulatorPoint(x: 0.5, y: 0.99),
                    to: SimulatorPoint(x: 0.5, y: max(0.01, 0.99 - distance))
                ),
                .bottom
            )
        default:
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.uiGesturePresetInvalid",
                defaultValue: "The Simulator gesture preset is invalid"
            ))
        }
    }

    private func simulatorUIDirection(
        _ value: String
    ) throws -> SimulatorUIAutomationDirection {
        guard let direction = SimulatorUIAutomationDirection(rawValue: value) else {
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.uiDirectionInvalid",
                defaultValue: "The Simulator UI direction is invalid"
            ))
        }
        return direction
    }

    private func simulatorUIRole(_ value: String) throws -> SimulatorUIAutomationRole {
        let raw = value.lowercased().replacingOccurrences(of: "_", with: "-")
        let normalized = switch raw {
        case "keyboardkey": "keyboard-key"
        case "scrollview": "scroll-view"
        case "textfield": "text-field"
        default: raw
        }
        guard let role = SimulatorUIAutomationRole(rawValue: normalized) else {
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.uiRoleInvalid",
                defaultValue: "The Simulator UI role is invalid"
            ))
        }
        return role
    }

    private func simulatorUIDelay(_ milliseconds: Int) async throws {
        guard milliseconds > 0 else { return }
        try await scheduler.nextEvent(after: .milliseconds(milliseconds))
    }

    private func simulatorUIMonotonicNowMilliseconds() -> Int64 {
        scheduler.monotonicNowMilliseconds()
    }

    private func simulatorUIWallTimeNowMilliseconds() -> Int64 {
        scheduler.wallTimeNowMilliseconds()
    }

    private func simulatorUIGestureActionPayload(
        type: String,
        elementRef: String,
        direction: SimulatorUIAutomationDirection,
        points: SimulatorUIAutomationGesturePoints,
        durationMilliseconds: Int,
        target: SimulatorUIAutomationElementRecord
    ) -> [String: JSONValue] {
        [
            "type": .string(type),
            "element_ref": .string(elementRef),
            "direction": .string(direction.rawValue),
            "from": simulatorUIPointPayload(points.from),
            "to": simulatorUIPointPayload(points.to),
            "duration_milliseconds": .int(Int64(durationMilliseconds)),
            "target": simulatorUIElementPayload(target.element),
        ]
    }

    private func simulatorUIUnchangedPayload(
        _ snapshot: SimulatorUIAutomationSnapshot
    ) -> JSONValue {
        .object([
            "type": .string("runtime-snapshot-unchanged"),
            "protocol": .string(snapshot.protocol),
            "simulator_id": .string(snapshot.simulatorID),
            "screen_hash": .string(snapshot.screenHash),
            "seq": .int(Int64(snapshot.sequence)),
        ])
    }

    private func simulatorUISnapshotPayload(
        _ snapshot: SimulatorUIAutomationSnapshot
    ) -> JSONValue {
        .object([
            "type": .string(snapshot.type),
            "protocol": .string(snapshot.protocol),
            "simulator_id": .string(snapshot.simulatorID),
            "screen_hash": .string(snapshot.screenHash),
            "seq": .int(Int64(snapshot.sequence)),
            "captured_at_ms": .int(snapshot.capturedAtMilliseconds),
            "expires_at_ms": .int(snapshot.expiresAtMilliseconds),
            "elements": .array(snapshot.elements.map(simulatorUIElementPayload)),
            "actions": .array(snapshot.actions.map { hint in
                .object([
                    "action": .string(hint.action.rawValue),
                    "element_ref": .string(hint.elementRef),
                    "label": hint.label.map(JSONValue.string) ?? .null,
                ])
            }),
            "truncated": .bool(snapshot.isTruncated),
            "truncated_fields": .array(
                snapshot.truncatedFields.map { .string($0.rawValue) }
            ),
        ])
    }

    private func simulatorUIElementPayload(
        _ element: SimulatorUIAutomationElement
    ) -> JSONValue {
        .object([
            "ref": .string(element.ref),
            "role": element.role.map { .string($0.rawValue) } ?? .null,
            "label": element.label.map(JSONValue.string) ?? .null,
            "value": element.value.map(JSONValue.string) ?? .null,
            "identifier": element.identifier.map(JSONValue.string) ?? .null,
            "frame": .object([
                "x": .double(element.frame.x),
                "y": .double(element.frame.y),
                "width": .double(element.frame.width),
                "height": .double(element.frame.height),
            ]),
            "state": .object([
                "enabled": .bool(element.state.isEnabled),
                "focused": element.state.isFocused.map(JSONValue.bool) ?? .null,
                "selected": element.state.isSelected.map(JSONValue.bool) ?? .null,
                "visible": .bool(element.state.isVisible),
            ]),
            "actions": .array(element.actions.map { .string($0.rawValue) }),
        ])
    }

    private func simulatorUIPointPayload(_ point: SimulatorPoint) -> JSONValue {
        .object(["x": .double(point.x), "y": .double(point.y)])
    }

    private func invalidSimulatorOperation(_ message: String) -> SimulatorFailure {
        SimulatorFailure(code: "invalid_params", message: message, isRecoverable: true)
    }
}
