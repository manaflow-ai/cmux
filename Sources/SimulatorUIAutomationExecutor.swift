import CmuxControlSocket
import CmuxSimulator
import CmuxSimulatorUI
import Foundation

/// Executes serialized UI automation against one Simulator pane coordinator.
@MainActor
struct SimulatorUIAutomationExecutor {
    private let timing: any SimulatorUIAutomationTiming

    init(
        timing: any SimulatorUIAutomationTiming = ContinuousSimulatorUIAutomationTiming()
    ) {
        self.timing = timing
    }

    func perform(
        _ operation: ControlSimulatorOperation,
        coordinator: SimulatorPaneCoordinator
    ) async throws -> JSONValue {
        switch operation {
        case let .uiSnapshot(sinceScreenHash):
            return try await coordinator.withUIAutomationTransaction {
                let record = try await captureSimulatorUIAutomationSnapshot(
                    coordinator: coordinator
                )
                if sinceScreenHash == record.snapshot.screenHash {
                    return simulatorUIUnchangedPayload(record.snapshot)
                }
                return simulatorUISnapshotPayload(record.snapshot)
            }
        case let .uiWait(wait):
            return try await coordinator.withUIAutomationTransaction {
                try await waitForSimulatorUI(wait, coordinator: coordinator)
            }
        case let .uiAction(action):
            return try await coordinator.withUIAutomationTransaction {
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
        default:
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.uiOperationInvalid",
                defaultValue: "The Simulator UI automation operation is invalid"
            ))
        }
    }

    private func performSimulatorUIAction(
        _ action: ControlSimulatorUIAction,
        coordinator: SimulatorPaneCoordinator
    ) async throws -> JSONValue {
        let previousScreenHash = try await preflightSimulatorUIAction(
            action,
            coordinator: coordinator
        )
        let actionPayload: [String: JSONValue]
        var postActionSettleDelayMilliseconds = 0
        switch action {
        case let .tap(elementRef, preDelayMilliseconds, postDelayMilliseconds):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            let target = try resolveSimulatorUIElement(
                ref: elementRef,
                requiredActions: [.tap],
                coordinator: coordinator
            )
            try await simulatorUIDelay(preDelayMilliseconds)
            try await performSimulatorUITap(target, coordinator: coordinator)
            try await simulatorUIDelay(postDelayMilliseconds)
            actionPayload = [
                "type": .string("tap"),
                "element_ref": .string(elementRef),
                "x": .double(target.activationPoint.x),
                "y": .double(target.activationPoint.y),
            ]
        case let .touch(elementRef, down, up, delayMilliseconds):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            let target = try resolveSimulatorUIElement(
                ref: elementRef,
                requiredActions: [.touch],
                coordinator: coordinator
            )
            let events = simulatorUITouchEvents(
                point: target.activationPoint,
                down: down,
                up: up,
                coordinator: coordinator
            )
            _ = try await coordinator.perform(.interactive(.touch(
                events: events,
                holdMilliseconds: delayMilliseconds
            )))
            actionPayload = [
                "type": .string("touch"),
                "element_ref": .string(elementRef),
                "down": .bool(down),
                "up": .bool(up),
                "x": .double(target.activationPoint.x),
                "y": .double(target.activationPoint.y),
            ]
        case let .swipe(
            elementRef, rawDirection, durationMilliseconds, distance, steps,
            preDelayMilliseconds, postDelayMilliseconds
        ):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            let target = try resolveSimulatorUIElement(
                ref: elementRef,
                requiredActions: [.swipeWithin],
                coordinator: coordinator
            )
            let record = try currentSimulatorUISnapshot(coordinator: coordinator)
            let direction = try simulatorUIDirection(rawDirection)
            guard let points = record.swipePoints(
                elementRef: elementRef,
                direction: direction,
                distance: distance
            ) else {
                throw simulatorUITargetNotActionable(elementRef)
            }
            try await simulatorUIDelay(preDelayMilliseconds)
            try await performSimulatorUITimedGesture(
                points: points,
                edge: .none,
                steps: steps,
                durationMilliseconds: durationMilliseconds,
                coordinator: coordinator
            )
            try await simulatorUIDelay(postDelayMilliseconds)
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
            preDelayMilliseconds, postDelayMilliseconds
        ):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            let target = try resolveSimulatorUIElement(
                ref: elementRef,
                requiredActions: [.touch, .swipeWithin],
                coordinator: coordinator
            )
            let record = try currentSimulatorUISnapshot(coordinator: coordinator)
            let direction = try simulatorUIDirection(rawDirection)
            guard let points = record.dragPoints(
                elementRef: elementRef,
                direction: direction,
                distance: distance
            ) else {
                throw simulatorUITargetNotActionable(elementRef)
            }
            try await simulatorUIDelay(preDelayMilliseconds)
            try await performSimulatorUITimedGesture(
                points: points,
                edge: .none,
                steps: steps,
                durationMilliseconds: durationMilliseconds,
                coordinator: coordinator
            )
            try await simulatorUIDelay(postDelayMilliseconds)
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
            let target = try resolveSimulatorUIElement(
                ref: elementRef,
                requiredActions: [.longPress],
                coordinator: coordinator
            )
            let events = simulatorUITouchEvents(
                point: target.activationPoint,
                down: true,
                up: true,
                coordinator: coordinator
            )
            _ = try await coordinator.perform(.interactive(.touch(
                events: events,
                holdMilliseconds: durationMilliseconds
            )))
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
            let target = try resolveSimulatorUIElement(
                ref: elementRef,
                requiredActions: [.typeText],
                coordinator: coordinator
            )
            let sequence: SimulatorTextInputSequence
            do {
                sequence = try SimulatorUSKeyboardTextEncoder().encode(text)
            } catch {
                throw invalidSimulatorOperation(String(
                    localized: "cli.simulator.error.uiTextUnsupported",
                    defaultValue: "The text cannot be encoded by Simulator's US keyboard input"
                ))
            }
            try await performSimulatorUITap(target, coordinator: coordinator)
            if replaceExisting {
                _ = try await coordinator.perform(.interactive(.keyChord(
                    modifiers: [0xE3],
                    key: 0x04
                )))
            }
            _ = try await coordinator.perform(.interactive(.typeText(sequence)))
            actionPayload = [
                "type": .string("type-text"),
                "element_ref": .string(elementRef),
                "text_length": .int(Int64(text.count)),
                "replace_existing": .bool(replaceExisting),
            ]
        case let .keyPress(keyCode, durationMilliseconds):
            try requireSimulatorCapability(.keyboard, coordinator: coordinator)
            _ = try await coordinator.perform(.interactive(.keyPresses(
                usages: [keyCode],
                pressDurationMilliseconds: durationMilliseconds,
                interKeyDelayMilliseconds: 0
            )))
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
            postActionSettleDelayMilliseconds = 750
        case let .gesturePreset(
            preset, durationMilliseconds, distance, steps,
            preDelayMilliseconds, postDelayMilliseconds
        ):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            let (points, edge) = try simulatorUIGesturePreset(
                preset,
                distance: distance
            )
            try await simulatorUIDelay(preDelayMilliseconds)
            try await performSimulatorUITimedGesture(
                points: points,
                edge: edge,
                steps: steps,
                durationMilliseconds: durationMilliseconds,
                coordinator: coordinator
            )
            try await simulatorUIDelay(postDelayMilliseconds)
            actionPayload = [
                "type": .string("gesture"),
                "gesture": .string(preset),
                "from": simulatorUIPointPayload(points.from),
                "to": simulatorUIPointPayload(points.to),
                "duration_milliseconds": .int(Int64(durationMilliseconds)),
            ]
        case let .batch(steps):
            try requireSimulatorCapability(.touch, coordinator: coordinator)
            let targets = try steps.map { step in
                (
                    step,
                    try resolveSimulatorUIElement(
                        ref: step.elementRef,
                        requiredActions: [.tap],
                        coordinator: coordinator
                    )
                )
            }
            for (step, target) in targets {
                try await simulatorUIDelay(step.preDelayMilliseconds)
                try await performSimulatorUITap(target, coordinator: coordinator)
                try await simulatorUIDelay(step.postDelayMilliseconds)
            }
            actionPayload = [
                "type": .string("batch"),
                "step_count": .int(Int64(steps.count)),
            ]
        }

        coordinator.clearUIAutomationSnapshot()
        var result: [String: JSONValue] = [
            "completed": .bool(true),
            "action": .object(actionPayload),
        ]
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
            result["snapshot_warning"] = .string(String(
                localized: "cli.simulator.warning.uiSnapshotRefreshFailed",
                defaultValue: "The action succeeded, but the refreshed UI snapshot was unavailable"
            ))
            result["ui_error"] = failure.uiError
        } catch {
            coordinator.clearUIAutomationSnapshot()
            result["snapshot_warning"] = .string(String(
                localized: "cli.simulator.warning.uiSnapshotRefreshFailed",
                defaultValue: "The action succeeded, but the refreshed UI snapshot was unavailable"
            ))
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
    ) async throws -> String? {
        let elementRefs = simulatorUIElementRefs(in: action)
        guard !elementRefs.isEmpty else {
            return try? coordinator.currentUIAutomationSnapshot(
                nowMilliseconds: simulatorUINowMilliseconds()
            ).snapshot.screenHash
        }

        let current = try currentSimulatorUISnapshot(coordinator: coordinator)
        for elementRef in elementRefs where current.element(ref: elementRef) == nil {
            throw simulatorUIReferenceFailure(
                SimulatorUIAutomationReferenceError.elementRefNotFound(elementRef)
            )
        }
        let refreshed = try await captureSimulatorUIAutomationSnapshot(
            coordinator: coordinator
        )
        guard refreshed.snapshot.screenHash == current.snapshot.screenHash else {
            throw SimulatorUIAutomationFailure(
                code: "ui_state_changed",
                message: String(
                    localized: "cli.simulator.error.uiStateChanged",
                    defaultValue: "The Simulator UI changed after the element ref was captured"
                ),
                recoveryHint: simulatorUICaptureRecoveryHint(),
                elementRef: elementRefs.first
            )
        }
        return current.snapshot.screenHash
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

    private func waitForSimulatorUI(
        _ wait: ControlSimulatorUIWait,
        coordinator: SimulatorPaneCoordinator
    ) async throws -> JSONValue {
        try requireSimulatorCapability(.accessibility, coordinator: coordinator)
        let startedAt = simulatorUINowMilliseconds()
        let deadline = startedAt + Int64(wait.timeoutMilliseconds)
        let selector: SimulatorUIAutomationSelector?
        if let elementRef = wait.elementRef {
            do {
                selector = try coordinator.stableUIAutomationSelector(
                    ref: elementRef,
                    nowMilliseconds: startedAt
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

        var stableHash: String?
        var stableSince: Int64?
        var latestRecord: SimulatorUIAutomationSnapshotRecord?
        // CoreSimulator's accessibility translator exposes snapshots but no
        // change notification, so bounded wait predicates require sampling.
        while true {
            try Task.checkCancellation()
            let record = try await captureSimulatorUIAutomationSnapshot(
                coordinator: coordinator
            )
            latestRecord = record
            let now = simulatorUINowMilliseconds()
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
            guard now < deadline else { break }
            try await simulatorUIDelay(
                min(wait.pollIntervalMilliseconds, Int(deadline - now))
            )
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

    private func simulatorUIWaitMatches(
        _ wait: ControlSimulatorUIWait,
        selector: SimulatorUIAutomationSelector?,
        record: SimulatorUIAutomationSnapshotRecord,
        nowMilliseconds: Int64,
        stableHash: inout String?,
        stableSince: inout Int64?
    ) throws -> (didMatch: Bool, elements: [SimulatorUIAutomationElement]) {
        if wait.predicate == "settled" {
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
        switch wait.predicate {
        case "exists":
            return (!candidates.isEmpty, candidates)
        case "gone":
            if selector == nil, candidates.count > 1,
               !record.candidatesShareMatchingText(candidates, containing: wait.text ?? "") {
                throw simulatorUIAmbiguousWaitFailure(candidates)
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
        coordinator: SimulatorPaneCoordinator
    ) async throws -> SimulatorUIAutomationSnapshotRecord {
        try requireSimulatorCapability(.accessibility, coordinator: coordinator)
        guard let simulatorID = coordinator.selectedDeviceID else {
            throw invalidSimulatorOperation(String(
                localized: "cli.simulator.error.deviceRequired",
                defaultValue: "The Simulator pane has no selected device"
            ))
        }
        let result: SimulatorControlResult
        do {
            result = try await coordinator.perform(.readAccessibility)
        } catch let failure as SimulatorFailure {
            throw simulatorUISnapshotCaptureFailure(failure.message)
        } catch {
            throw simulatorUISnapshotCaptureFailure(String(
                localized: "cli.simulator.error.accessibilityMissing",
                defaultValue: "The Simulator worker returned no accessibility snapshot"
            ))
        }
        guard case let .accessibility(snapshot) = result else {
            throw simulatorUISnapshotCaptureFailure(String(
                localized: "cli.simulator.error.accessibilityMissing",
                defaultValue: "The Simulator worker returned no accessibility snapshot"
            ))
        }
        do {
            return try coordinator.recordUIAutomationSnapshot(
                snapshot,
                simulatorID: simulatorID,
                capturedAtMilliseconds: simulatorUINowMilliseconds()
            )
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
        let deadline = simulatorUINowMilliseconds() + 2_500
        var previousHash: String?
        var stableSince: Int64?
        // The accessibility bridge has no event stream. Sampling is bounded,
        // cancellable, and uses the injected timing seam.
        while true {
            let record = try await captureSimulatorUIAutomationSnapshot(
                coordinator: coordinator
            )
            let now = simulatorUINowMilliseconds()
            if previousHash == record.snapshot.screenHash {
                if now - (stableSince ?? now) >= 100 {
                    return record
                }
            } else {
                previousHash = record.snapshot.screenHash
                stableSince = now
            }
            guard now < deadline else {
                throw simulatorUISnapshotCaptureFailure(String(
                    localized: "cli.simulator.error.uiSnapshotDidNotSettle",
                    defaultValue: "The refreshed Simulator UI snapshot did not settle"
                ))
            }
            try await simulatorUIDelay(min(100, Int(deadline - now)))
        }
    }

    private func currentSimulatorUISnapshot(
        coordinator: SimulatorPaneCoordinator
    ) throws -> SimulatorUIAutomationSnapshotRecord {
        do {
            return try coordinator.currentUIAutomationSnapshot(
                nowMilliseconds: simulatorUINowMilliseconds()
            )
        } catch {
            throw simulatorUIReferenceFailure(error)
        }
    }

    private func resolveSimulatorUIElement(
        ref: String,
        requiredActions: [SimulatorUIAutomationActionName],
        coordinator: SimulatorPaneCoordinator
    ) throws -> SimulatorUIAutomationElementRecord {
        do {
            return try coordinator.resolveUIAutomationElement(
                ref: ref,
                requiredActions: requiredActions,
                nowMilliseconds: simulatorUINowMilliseconds()
            )
        } catch {
            throw simulatorUIReferenceFailure(error)
        }
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

    private func simulatorUISnapshotCaptureFailure(
        _ message: String
    ) -> SimulatorUIAutomationFailure {
        SimulatorUIAutomationFailure(
            code: "snapshot_capture_failed",
            message: message,
            recoveryHint: simulatorUICaptureRecoveryHint()
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
        coordinator: SimulatorPaneCoordinator
    ) async throws {
        let events = simulatorUITouchEvents(
            point: target.activationPoint,
            down: true,
            up: true,
            coordinator: coordinator
        )
        _ = try await coordinator.perform(.interactive(.gesture(events)))
    }

    private func simulatorUITouchEvents(
        point: SimulatorPoint,
        down: Bool,
        up: Bool,
        coordinator: SimulatorPaneCoordinator
    ) -> [SimulatorPointerEvent] {
        var events: [SimulatorPointerEvent] = []
        if down {
            events.append(SimulatorPointerEvent(phase: .began, primary: point))
        }
        if up {
            events.append(SimulatorPointerEvent(phase: .ended, primary: point))
        }
        return simulatorUIRawPointerEvents(events, coordinator: coordinator)
    }

    private func performSimulatorUITimedGesture(
        points: SimulatorUIAutomationGesturePoints,
        edge: SimulatorEdge,
        steps: Int,
        durationMilliseconds: Int,
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
            events: simulatorUIRawPointerEvents(events, coordinator: coordinator),
            durationMilliseconds: durationMilliseconds
        )))
    }

    private func simulatorUIRawPointerEvents(
        _ events: [SimulatorPointerEvent],
        coordinator: SimulatorPaneCoordinator
    ) -> [SimulatorPointerEvent] {
        guard let display = coordinator.display else { return events }
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
        try await timing.sleep(for: .milliseconds(milliseconds))
    }

    private func simulatorUINowMilliseconds() -> Int64 {
        timing.nowMilliseconds()
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
}
