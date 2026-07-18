import Foundation
import OSLog
import QuartzCore
import SwiftUI
@preconcurrency import UIKit

/// Opt-in interaction intervals used by the Priority 8 Instruments workload.
///
/// The implementation is compiled into Release builds, but remains inert unless
/// `CMUX_IOS_INTERACTION_SIGNPOSTS=1` and an OS signpost recorder is active.
/// Workspace presentation intervals settle after both the authoritative model
/// completion and UIKit appearance. Successful mutation intervals remain open
/// until their expected stable-ID state reaches a UIKit layout and Core
/// Animation display commit.
@MainActor
final class MobileInteractionProfilingSignposts {
    struct Interval {
        fileprivate let name: StaticString
        fileprivate let state: OSSignpostIntervalState
    }

    enum Outcome: String {
        case settled
        case failed
        case cancelled
        case superseded
    }

    private struct PendingInterval {
        let contextID: String
        let generation: UUID
        let interval: Interval
    }

    private struct PendingWorkspaceInterval {
        let contextID: String
        let generation: UUID
        let interval: Interval
        var settlement = MobileInteractionPresentationSettlement()
    }

    private struct PendingSelection {
        let workspaceID: String
        let terminalID: String
        let interval: Interval
    }

    private let signposter: OSSignposter
    private let isEnvironmentEnabled: Bool
    private var pendingWorkspaceOpen: PendingWorkspaceInterval?
    private var pendingTerminalHierarchyOpen: PendingInterval?
    private var pendingTerminalSelection: PendingSelection?

    var isActive: Bool {
        isEnvironmentEnabled && signposter.isEnabled
    }

    init(
        subsystem: String = "com.cmuxterm.mobile",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        signposter = OSSignposter(
            subsystem: subsystem,
            category: "P8Interactions"
        )
        isEnvironmentEnabled = environment["CMUX_IOS_INTERACTION_SIGNPOSTS"] == "1"
    }

    func beginWorkspaceOpen(workspaceID: String) -> UUID? {
        if let pendingWorkspaceOpen {
            end(pendingWorkspaceOpen.interval, outcome: .superseded)
        }
        let generation = UUID()
        pendingWorkspaceOpen = begin("WorkspaceOpen").map {
            PendingWorkspaceInterval(contextID: workspaceID, generation: generation, interval: $0)
        }
        return pendingWorkspaceOpen?.generation
    }

    func workspaceOpenGeneration(workspaceID: String) -> UUID? {
        guard pendingWorkspaceOpen?.contextID == workspaceID else { return nil }
        return pendingWorkspaceOpen?.generation
    }

    func markWorkspaceOpenModelSettled(workspaceID: String, generation: UUID?) {
        markWorkspaceOpen(
            workspaceID: workspaceID,
            generation: generation,
            milestone: .model
        )
    }

    func markWorkspaceOpenPresented(workspaceID: String, generation: UUID?) {
        markWorkspaceOpen(
            workspaceID: workspaceID,
            generation: generation,
            milestone: .presentation
        )
    }

    func cancelWorkspaceOpen(workspaceID: String, generation: UUID?) {
        guard pendingWorkspaceOpen?.contextID == workspaceID,
              pendingWorkspaceOpen?.generation == generation else { return }
        end(pendingWorkspaceOpen?.interval, outcome: .cancelled)
        pendingWorkspaceOpen = nil
    }

    func failWorkspaceOpen(workspaceID: String, generation: UUID?) {
        guard pendingWorkspaceOpen?.contextID == workspaceID,
              pendingWorkspaceOpen?.generation == generation else { return }
        end(pendingWorkspaceOpen?.interval, outcome: .failed)
        pendingWorkspaceOpen = nil
    }

    private func markWorkspaceOpen(
        workspaceID: String,
        generation: UUID?,
        milestone: MobileInteractionPresentationSettlement.Milestone
    ) {
        guard var pendingWorkspaceOpen,
              pendingWorkspaceOpen.contextID == workspaceID,
              pendingWorkspaceOpen.generation == generation else { return }
        guard pendingWorkspaceOpen.settlement.mark(milestone) else {
            self.pendingWorkspaceOpen = pendingWorkspaceOpen
            return
        }
        end(pendingWorkspaceOpen.interval, outcome: .settled)
        self.pendingWorkspaceOpen = nil
    }

    func beginTerminalHierarchyOpen(workspaceID: String) -> UUID? {
        if let pendingTerminalHierarchyOpen {
            end(pendingTerminalHierarchyOpen.interval, outcome: .superseded)
        }
        let generation = UUID()
        pendingTerminalHierarchyOpen = begin("TerminalHierarchyOpen").map {
            PendingInterval(contextID: workspaceID, generation: generation, interval: $0)
        }
        return pendingTerminalHierarchyOpen?.generation
    }

    func endTerminalHierarchyOpen(workspaceID: String, generation: UUID?) {
        guard pendingTerminalHierarchyOpen?.contextID == workspaceID,
              pendingTerminalHierarchyOpen?.generation == generation else { return }
        end(pendingTerminalHierarchyOpen?.interval, outcome: .settled)
        pendingTerminalHierarchyOpen = nil
    }

    func cancelTerminalHierarchyOpen(workspaceID: String, generation: UUID?) {
        guard pendingTerminalHierarchyOpen?.contextID == workspaceID,
              pendingTerminalHierarchyOpen?.generation == generation else { return }
        end(pendingTerminalHierarchyOpen?.interval, outcome: .cancelled)
        pendingTerminalHierarchyOpen = nil
    }

    func beginTerminalSelection(
        workspaceID: String,
        terminalID: String,
        paneSwitch: Bool
    ) {
        if let pendingTerminalSelection {
            end(pendingTerminalSelection.interval, outcome: .superseded)
        }
        let interval: Interval?
        if paneSwitch {
            interval = begin("PaneSwitch")
        } else {
            interval = begin("TerminalSwitch")
        }
        pendingTerminalSelection = interval.map {
            PendingSelection(
                workspaceID: workspaceID,
                terminalID: terminalID,
                interval: $0
            )
        }
    }

    func endTerminalSelection(workspaceID: String, selectedTerminalID: String?) {
        guard let pendingTerminalSelection else { return }
        let outcome: Outcome = pendingTerminalSelection.workspaceID == workspaceID
            && pendingTerminalSelection.terminalID == selectedTerminalID
            ? .settled
            : .cancelled
        end(pendingTerminalSelection.interval, outcome: outcome)
        self.pendingTerminalSelection = nil
    }

    func beginTerminalReorder() -> Interval? {
        begin("TerminalReorder")
    }

    func endTerminalReorder(_ interval: Interval?, outcome: Outcome) {
        end(interval, outcome: outcome)
    }

    func beginTerminalCreate() -> Interval? {
        begin("TerminalCreate")
    }

    func endTerminalCreate(_ interval: Interval?, outcome: Outcome) {
        end(interval, outcome: outcome)
    }

    func beginTerminalClose() -> Interval? {
        begin("TerminalClose")
    }

    func endTerminalClose(_ interval: Interval?, outcome: Outcome) {
        end(interval, outcome: outcome)
    }

    private func begin(_ name: StaticString) -> Interval? {
        guard isEnvironmentEnabled, signposter.isEnabled else { return nil }
        return Interval(
            name: name,
            state: signposter.beginInterval(name, id: signposter.makeSignpostID())
        )
    }

    private func end(_ interval: Interval?, outcome: Outcome) {
        guard let interval else { return }
        signposter.endInterval(
            interval.name,
            interval.state,
            "outcome=\(outcome.rawValue, privacy: .public)"
        )
    }
}

/// Reports only after UIKit confirms that the hosting controller completed its
/// appearance transition.
struct MobileInteractionPresentationDidAppearProbe: UIViewControllerRepresentable {
    let onDidAppear: @MainActor () -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller(onDidAppear: onDidAppear)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {}

    @MainActor
    final class Controller: UIViewController {
        let onDidAppear: @MainActor () -> Void

        init(onDidAppear: @escaping @MainActor () -> Void) {
            self.onDidAppear = onDidAppear
            super.init(nibName: nil, bundle: nil)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            onDidAppear()
        }
    }
}

/// Reports one generation only after its ready SwiftUI state reaches a UIKit
/// layout pass and the associated Core Animation display transaction commits.
struct MobileInteractionLayoutDisplayCommitProbe: UIViewControllerRepresentable {
    let generation: UUID
    let isReady: Bool
    let onCommitted: @MainActor (UUID) -> Void

    func makeUIViewController(context: Context) -> Controller {
        Controller()
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.configure(
            generation: generation,
            isReady: isReady,
            onCommitted: onCommitted
        )
    }

    @MainActor
    final class Controller: UIViewController {
        private var scheduledGeneration: UUID?
        private var scheduledToken = UUID()
        private var committedGeneration: UUID?
        private var isCommitEnqueued = false
        private var onCommitted: (@MainActor (UUID) -> Void)?

        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
        }

        func configure(
            generation: UUID,
            isReady: Bool,
            onCommitted: @escaping @MainActor (UUID) -> Void
        ) {
            self.onCommitted = onCommitted
            guard isReady else {
                invalidateScheduledCommit()
                return
            }
            guard committedGeneration != generation else { return }
            if scheduledGeneration != generation {
                scheduledGeneration = generation
                scheduledToken = UUID()
                isCommitEnqueued = false
            }
            view.setNeedsLayout()
            view.superview?.setNeedsLayout()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            guard let generation = scheduledGeneration,
                  !isCommitEnqueued else { return }
            isCommitEnqueued = true
            let token = scheduledToken
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            CATransaction.setCompletionBlock { [weak self] in
                Task { @MainActor [weak self] in
                    self?.complete(generation: generation, token: token)
                }
            }
            view.layer.setNeedsDisplay()
            view.layer.displayIfNeeded()
            CATransaction.commit()
        }

        private func invalidateScheduledCommit() {
            scheduledGeneration = nil
            scheduledToken = UUID()
            isCommitEnqueued = false
        }

        private func complete(generation: UUID, token: UUID) {
            guard scheduledGeneration == generation,
                  scheduledToken == token else { return }
            committedGeneration = generation
            scheduledGeneration = nil
            isCommitEnqueued = false
            onCommitted?(generation)
        }
    }
}

private struct MobileInteractionProfilingSignpostsReference: @unchecked Sendable {
    let signposts: MobileInteractionProfilingSignposts?
}

private struct MobileInteractionProfilingSignpostsEnvironmentKey: EnvironmentKey {
    static let defaultValue = MobileInteractionProfilingSignpostsReference(signposts: nil)
}

extension EnvironmentValues {
    var mobileInteractionProfilingSignposts: MobileInteractionProfilingSignposts? {
        get { self[MobileInteractionProfilingSignpostsEnvironmentKey.self].signposts }
        set {
            self[MobileInteractionProfilingSignpostsEnvironmentKey.self] =
                MobileInteractionProfilingSignpostsReference(signposts: newValue)
        }
    }
}

struct MobileInteractionPresentationSettlement: Equatable {
    enum Milestone {
        case model
        case presentation
    }

    private(set) var modelSettled = false
    private(set) var presentationSettled = false

    @discardableResult
    mutating func mark(_ milestone: Milestone) -> Bool {
        switch milestone {
        case .model:
            modelSettled = true
        case .presentation:
            presentationSettled = true
        }
        return modelSettled && presentationSettled
    }
}
