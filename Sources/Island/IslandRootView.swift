// Sources/Island/IslandRootView.swift

import AppKit
import Combine
import SwiftUI

/// SwiftUI root of the cmux Island overlay.
///
/// Two visual states — closed (minimal pill on the left extension of the
/// notch) and opened (rounded panel below the notch with session rows).
struct IslandRootView: View {

    @ObservedObject var viewModel: IslandRootViewModel

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(
                topCornerRadius: viewModel.topCornerRadius,
                bottomCornerRadius: viewModel.bottomCornerRadius
            )
            .fill(.black)
            .frame(
                width: viewModel.shapeSize.width,
                height: viewModel.shapeSize.height
            )
            .shadow(
                color: viewModel.isOpen ? .black.opacity(0.7) : .clear,
                radius: 8
            )
            .animation(
                viewModel.isOpen
                    ? .spring(response: 0.42, dampingFraction: 0.8)
                    : .spring(response: 0.45, dampingFraction: 1.0),
                value: viewModel.isOpen
            )
            .onTapGesture {
                if !viewModel.isOpen { viewModel.open() }
            }
            .overlay(alignment: .top) {
                if viewModel.isOpen {
                    expandedContent
                        .padding(.top, viewModel.notchHeight + 4)
                        .frame(width: viewModel.shapeSize.width - 24)
                } else {
                    closedContent
                        .padding(.leading, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    // MARK: - Closed state — dot + count on the LEFT extension

    private var closedContent: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(nsColor: viewModel.aggregateColor))
                .frame(width: 6, height: 6)
                .shadow(color: Color(nsColor: viewModel.aggregateColor).opacity(0.6), radius: 3)
            Text(verbatim: "\(viewModel.sessions.count)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .frame(height: viewModel.notchHeight, alignment: .leading)
    }

    // MARK: - Expanded state — list of session rows

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "island.header.title", defaultValue: "cmux Island"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .padding(.top, 6)

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.sessions) { session in
                        sessionRow(session)
                    }
                }
            }
            .frame(maxHeight: 440)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .onExitCommand { viewModel.close() }
    }

    @ViewBuilder
    private func sessionRow(_ session: IslandSession) -> some View {
        Button {
            viewModel.jump(to: session)
        } label: {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: session.agentKind.color))
                    .frame(width: 20, height: 20)
                    .overlay(
                        // Monogram is a structural identifier (single letter
                        // per agent kind), not a translatable string.
                        Text(verbatim: session.agentKind.monogram)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    // Composed structural strings — separators and interpolated
                    // values (workspace/panel titles, elapsed time) are not
                    // translated as wholes. `Text(verbatim:)` declares this
                    // intent so the localization scanner doesn't flag them.
                    Text(verbatim: "\(session.workspaceTitle) · \(session.panelTitle)")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(verbatim: "\(session.agentKind.displayName) · \(relativeTime(since: session.lastActivity))")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 4)

                phasePill(session.phase)
                if session.unreadCount > 0 {
                    Text(verbatim: "·\(session.unreadCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func phasePill(_ phase: IslandSessionPhase) -> some View {
        let style = phaseStyle(phase)
        Text(style.text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(style.background))
            .foregroundStyle(style.foreground)
    }

    private struct PhaseStyle {
        let background: Color
        let foreground: Color
        let text: String
    }

    private func phaseStyle(_ phase: IslandSessionPhase) -> PhaseStyle {
        switch phase {
        case .running:
            return PhaseStyle(
                background: Color(red: 0.04, green: 0.23, blue: 0.09),
                foreground: Color(red: 0.20, green: 0.82, blue: 0.35),
                text: String(localized: "island.phase.running", defaultValue: "RUNNING")
            )
        case .waiting:
            return PhaseStyle(
                background: Color(red: 0.29, green: 0.21, blue: 0.02),
                foreground: Color(red: 0.98, green: 0.80, blue: 0.24),
                text: String(localized: "island.phase.waiting", defaultValue: "WAITING")
            )
        case .error:
            return PhaseStyle(
                background: Color(red: 0.23, green: 0.07, blue: 0.07),
                foreground: Color(red: 0.97, green: 0.44, blue: 0.44),
                text: String(localized: "island.phase.error", defaultValue: "ERROR")
            )
        case .idle:
            return PhaseStyle(
                background: Color(red: 0.11, green: 0.16, blue: 0.22),
                foreground: Color(red: 0.49, green: 0.83, blue: 0.99),
                text: String(localized: "island.phase.idle", defaultValue: "IDLE")
            )
        case .unknown:
            return PhaseStyle(
                background: .white.opacity(0.12),
                foreground: .white.opacity(0.6),
                text: String(localized: "island.phase.unknown", defaultValue: "—")
            )
        }
    }

    private func relativeTime(since date: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3_600)h" }
        return "\(seconds / 86_400)d"
    }
}

// MARK: - View model

/// View model backing `IslandRootView`. Owns the open/closed state, the
/// current session snapshot, and delegates jump actions to a router.
@MainActor
final class IslandRootViewModel: ObservableObject {

    @Published private(set) var sessions: [IslandSession] = []
    @Published private(set) var isOpen: Bool = false

    let notchWidth: CGFloat
    let notchHeight: CGFloat

    // Geometry constants.
    private let closedSideExtent: CGFloat = 28
    private let openedWidth: CGFloat = 560
    private let openedMinHeight: CGFloat = 160
    private let rowHeight: CGFloat = 56
    private let openedMaxHeight: CGFloat = 540
    private let openedHeaderBuffer: CGFloat = 64

    private let router: IslandJumpRouter
    private var provider: IslandStateProvider?
    private var cancellable: AnyCancellable?

    init(notchWidth: CGFloat, notchHeight: CGFloat, router: IslandJumpRouter) {
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
        self.router = router
    }

    /// Attach to a state provider. Calling this again with a different
    /// provider replaces the subscription.
    func bind(to provider: IslandStateProvider) {
        self.provider = provider
        self.sessions = provider.currentSessions
        self.cancellable = provider.sessionsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessions in
                self?.sessions = sessions
            }
    }

    // MARK: Layout helpers

    var shapeSize: CGSize {
        if isOpen {
            let desired = openedHeaderBuffer + CGFloat(sessions.count) * rowHeight
            let clamped = min(max(desired, openedMinHeight), openedMaxHeight)
            return CGSize(width: openedWidth, height: clamped)
        } else {
            return CGSize(
                width: notchWidth + 2 * closedSideExtent,
                height: notchHeight
            )
        }
    }

    var topCornerRadius: CGFloat { isOpen ? 19 : 6 }
    var bottomCornerRadius: CGFloat { isOpen ? 24 : 14 }

    /// Highest-severity phase currently present, mapped to a single
    /// indicator color for the collapsed pill.
    var aggregateColor: NSColor {
        if sessions.contains(where: { $0.phase == .running }) {
            return .systemGreen
        }
        if sessions.contains(where: { $0.phase == .waiting }) {
            return .systemYellow
        }
        if sessions.contains(where: { $0.phase == .error }) {
            return .systemRed
        }
        return .systemGray
    }

    // MARK: Actions

    func open()  { isOpen = true  }
    func close() { isOpen = false }

    func jump(to session: IslandSession) {
        router.jump(to: session)
    }
}
