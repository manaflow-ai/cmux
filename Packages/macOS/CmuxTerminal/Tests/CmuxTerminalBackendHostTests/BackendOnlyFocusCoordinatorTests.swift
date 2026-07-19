import CmuxTerminalBackend
@testable import CmuxTerminalBackendHost
import Foundation
import Testing

@MainActor
@Suite("Backend-only focus coordinator")
struct BackendOnlyFocusCoordinatorTests {
    @Test("mounting never claims first responder before exact authority")
    func mountingDoesNotClaimFirstResponder() {
        let fixture = Fixture()
        fixture.coordinator.setWindowKey(true)

        fixture.registerTerminal(fixture.one, surface: fixture.surfaceOne)
        fixture.registerTerminal(fixture.two, surface: fixture.surfaceTwo)

        #expect(fixture.oneFocus.count == 0)
        #expect(fixture.twoFocus.count == 0)
        #expect(fixture.coordinator.firstResponderOwnedSlotID == nil)

        #expect(fixture.coordinator.installAuthoritativeActiveSlot(
            fixture.two,
            authorityRevision: 1
        ))

        #expect(fixture.oneFocus.count == 0)
        #expect(fixture.twoFocus.count == 1)
        #expect(fixture.coordinator.firstResponderOwnedSlotID == fixture.two)
    }

    @Test("key-window focus targets only the exact active terminal without fallback")
    func exactActiveTerminalReceivesProgrammaticFocus() {
        let fixture = Fixture()
        fixture.registerTerminal(fixture.one, surface: fixture.surfaceOne)
        fixture.registerTerminal(fixture.two, surface: fixture.surfaceTwo)
        fixture.coordinator.setWindowKey(true)
        #expect(fixture.coordinator.installAuthoritativeActiveSlot(
            fixture.two,
            authorityRevision: 1
        ))

        fixture.coordinator.unregister(slotID: fixture.two)

        #expect(fixture.oneFocus.count == 0)
        #expect(fixture.twoFocus.count == 1)
        #expect(fixture.coordinator.firstResponderOwnedSlotID == nil)
        #expect(fixture.submitter.actionsSnapshot().isEmpty)
    }

    @Test("pointer focus is immediate but styling waits for the applied absolute action")
    func pointerFocusWaitsForAppliedAction() async throws {
        let fixture = Fixture()
        fixture.registerTerminal(fixture.one, surface: fixture.surfaceOne)
        fixture.registerTerminal(fixture.two, surface: fixture.surfaceTwo)
        fixture.coordinator.setWindowKey(true)
        #expect(fixture.coordinator.installAuthoritativeActiveSlot(
            fixture.one,
            authorityRevision: 1
        ))
        var actions = fixture.submitter.actions.makeAsyncIterator()

        let request = Task {
            await fixture.coordinator.pointerClick(
                slotID: fixture.two,
                desiredSurfaceID: fixture.surfaceThree
            )
        }
        let action = try #require(await actions.next())

        #expect(fixture.twoFocus.count == 1)
        #expect(fixture.coordinator.authoritativeActiveSlotID == fixture.one)
        #expect(fixture.coordinator.isAuthoritativelyActive(fixture.one))
        #expect(!fixture.coordinator.isAuthoritativelyActive(fixture.two))
        #expect(action.targetSlotID == fixture.two)
        #expect(action.intents == [
            .selectSurface(
                workspaceID: fixture.two.workspaceID,
                screenID: fixture.two.screenID,
                paneID: fixture.two.paneID,
                surfaceID: fixture.surfaceThree
            ),
            .activatePane(
                workspaceID: fixture.two.workspaceID,
                screenID: fixture.two.screenID,
                paneID: fixture.two.paneID
            ),
        ])

        fixture.submitter.resume(
            BackendOnlyFocusActionReceipt(
                actionID: action.actionID,
                authorityRevision: 2,
                outcome: .applied,
                activeSlotID: fixture.two,
                selectedSurfaceID: fixture.surfaceThree
            )
        )

        #expect(await request.value == .applied)
        #expect(fixture.coordinator.authoritativeActiveSlotID == fixture.two)
        #expect(!fixture.coordinator.isAuthoritativelyActive(fixture.one))
        #expect(fixture.coordinator.isAuthoritativelyActive(fixture.two))
        #expect(fixture.twoFocus.count == 1)
    }

    @Test("out-of-order action receipts cannot overwrite newer authoritative styling")
    func outOfOrderReceiptsAreIgnored() async throws {
        let fixture = Fixture()
        fixture.registerTerminal(fixture.one, surface: fixture.surfaceOne)
        fixture.registerTerminal(fixture.two, surface: fixture.surfaceTwo)
        fixture.registerTerminal(fixture.three, surface: fixture.surfaceThree)
        fixture.coordinator.setWindowKey(true)
        #expect(fixture.coordinator.installAuthoritativeActiveSlot(
            fixture.one,
            authorityRevision: 1
        ))
        var actions = fixture.submitter.actions.makeAsyncIterator()

        let olderRequest = Task {
            await fixture.coordinator.pointerClick(slotID: fixture.two)
        }
        let olderAction = try #require(await actions.next())
        let newerRequest = Task {
            await fixture.coordinator.pointerClick(slotID: fixture.three)
        }
        let newerAction = try #require(await actions.next())

        fixture.submitter.resume(
            BackendOnlyFocusActionReceipt(
                actionID: newerAction.actionID,
                authorityRevision: 2,
                outcome: .applied,
                activeSlotID: fixture.three,
                selectedSurfaceID: fixture.surfaceThree
            )
        )
        #expect(await newerRequest.value == .applied)
        #expect(fixture.coordinator.authoritativeActiveSlotID == fixture.three)

        fixture.submitter.resume(
            BackendOnlyFocusActionReceipt(
                actionID: olderAction.actionID,
                authorityRevision: 3,
                outcome: .applied,
                activeSlotID: fixture.two,
                selectedSurfaceID: fixture.surfaceTwo
            )
        )

        #expect(await olderRequest.value == .ignoredStaleReceipt)
        #expect(fixture.coordinator.authoritativeActiveSlotID == fixture.three)
        #expect(fixture.coordinator.authorityRevision == 2)
    }

    @Test("placeholder slots change authority without receiving terminal focus")
    func placeholdersNeverReceiveTerminalFocus() async throws {
        let fixture = Fixture()
        fixture.registerTerminal(fixture.one, surface: fixture.surfaceOne)
        fixture.coordinator.register(
            slotID: fixture.two,
            content: .browserPlaceholder(selectedSurfaceID: fixture.surfaceTwo),
            requestFirstResponder: { fixture.twoFocus.request() }
        )
        fixture.coordinator.register(
            slotID: fixture.three,
            content: .unsupportedPlaceholder(selectedSurfaceID: fixture.surfaceThree),
            requestFirstResponder: { fixture.threeFocus.request() }
        )
        fixture.coordinator.setWindowKey(true)
        #expect(fixture.coordinator.installAuthoritativeActiveSlot(
            fixture.two,
            authorityRevision: 1
        ))

        #expect(fixture.twoFocus.count == 0)
        #expect(fixture.coordinator.firstResponderOwnedSlotID == nil)
        #expect(
            await fixture.coordinator.pointerClick(slotID: fixture.two)
                == .noChange
        )
        #expect(fixture.twoFocus.count == 0)
        #expect(fixture.coordinator.installAuthoritativeActiveSlot(
            fixture.three,
            authorityRevision: 2
        ))
        #expect(fixture.threeFocus.count == 0)
    }

    @Test("window resignation and unregister clear ownership without daemon mutation")
    func lifecycleClearsOnlyLocalOwnership() {
        let fixture = Fixture()
        fixture.registerTerminal(fixture.one, surface: fixture.surfaceOne)
        fixture.coordinator.setWindowKey(true)
        #expect(fixture.coordinator.installAuthoritativeActiveSlot(
            fixture.one,
            authorityRevision: 1
        ))
        #expect(fixture.coordinator.firstResponderOwnedSlotID == fixture.one)

        fixture.coordinator.setWindowKey(false)

        #expect(fixture.coordinator.firstResponderOwnedSlotID == nil)
        #expect(fixture.submitter.actionsSnapshot().isEmpty)

        fixture.coordinator.unregister(slotID: fixture.one)

        #expect(fixture.coordinator.registeredSlotCount == 0)
        #expect(fixture.coordinator.authoritativeActiveSlotID == fixture.one)
        #expect(fixture.submitter.actionsSnapshot().isEmpty)
    }

    @Test("stale authoritative publications cannot move styling or focus")
    func staleAuthoritativePublicationIsIgnored() {
        let fixture = Fixture()
        fixture.registerTerminal(fixture.one, surface: fixture.surfaceOne)
        fixture.registerTerminal(fixture.two, surface: fixture.surfaceTwo)
        fixture.coordinator.setWindowKey(true)
        #expect(fixture.coordinator.installAuthoritativeActiveSlot(
            fixture.two,
            authorityRevision: 2
        ))

        #expect(!fixture.coordinator.installAuthoritativeActiveSlot(
            fixture.one,
            authorityRevision: 1
        ))
        #expect(!fixture.coordinator.installAuthoritativeActiveSlot(
            fixture.one,
            authorityRevision: 2
        ))

        #expect(fixture.coordinator.authoritativeActiveSlotID == fixture.two)
        #expect(fixture.oneFocus.count == 0)
        #expect(fixture.twoFocus.count == 1)
    }
}

@MainActor
private final class Fixture {
    let submitter = ControlledFocusActionSubmitter()
    lazy var coordinator = BackendOnlyFocusCoordinator(
        submitAction: { [submitter] action in
            await submitter.submit(action)
        }
    )
    let logicalPresentationID = focusUUID(1)
    lazy var one = slot(pane: 1)
    lazy var two = slot(pane: 2)
    lazy var three = slot(pane: 3)
    let surfaceOne = SurfaceID(rawValue: focusUUID(101))
    let surfaceTwo = SurfaceID(rawValue: focusUUID(102))
    let surfaceThree = SurfaceID(rawValue: focusUUID(103))
    let oneFocus = FocusRequestSpy()
    let twoFocus = FocusRequestSpy()
    let threeFocus = FocusRequestSpy()

    func registerTerminal(
        _ slotID: BackendOnlyProjectionSlotID,
        surface: SurfaceID
    ) {
        let spy = switch slotID.paneID {
        case one.paneID: oneFocus
        case two.paneID: twoFocus
        default: threeFocus
        }
        coordinator.register(
            slotID: slotID,
            content: .terminal(selectedSurfaceID: surface),
            requestFirstResponder: { spy.request() }
        )
    }

    private func slot(pane: UInt64) -> BackendOnlyProjectionSlotID {
        BackendOnlyProjectionSlotID(
            logicalPresentationID: logicalPresentationID,
            workspaceID: WorkspaceID(rawValue: focusUUID(10)),
            screenID: ScreenID(rawValue: focusUUID(20)),
            paneID: PaneID(rawValue: focusUUID(30 + pane))
        )
    }
}

@MainActor
private final class FocusRequestSpy {
    private(set) var count = 0

    func request() -> Bool {
        count += 1
        return true
    }
}

@MainActor
private final class ControlledFocusActionSubmitter {
    let actions: AsyncStream<BackendOnlyFocusAction>
    private let actionContinuation: AsyncStream<BackendOnlyFocusAction>.Continuation
    private var recorded: [BackendOnlyFocusAction] = []
    private var waiters: [
        UInt64: CheckedContinuation<BackendOnlyFocusActionReceipt, Never>
    ] = [:]

    init() {
        (actions, actionContinuation) = AsyncStream.makeStream()
    }

    func submit(_ action: BackendOnlyFocusAction) async -> BackendOnlyFocusActionReceipt {
        recorded.append(action)
        actionContinuation.yield(action)
        return await withCheckedContinuation { continuation in
            waiters[action.actionID] = continuation
        }
    }

    func resume(_ receipt: BackendOnlyFocusActionReceipt) {
        waiters.removeValue(forKey: receipt.actionID)?.resume(returning: receipt)
    }

    func actionsSnapshot() -> [BackendOnlyFocusAction] {
        recorded
    }
}

private func focusUUID(_ value: UInt64) -> UUID {
    let suffix = String(format: "%012llX", value)
    return UUID(uuidString: "F0C00000-0000-0000-0000-\(suffix)")!
}
