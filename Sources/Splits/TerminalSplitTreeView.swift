import SwiftUI
import AppKit

struct TerminalSplitTreeView: View {
    @ObservedObject var tab: Tab
    let isTabActive: Bool
    let isResizing: Bool
    @State private var config = GhosttyConfig.load()
    @State private var lastActiveSize: CGSize = .zero
    @EnvironmentObject var notificationStore: TerminalNotificationStore

    var body: some View {
        let appearance = SplitAppearance(
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayColor: Color(nsColor: config.unfocusedSplitOverlayFill),
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity
        )
        let shouldFreeze = !isTabActive || isResizing
        Group {
            if let node = tab.splitTree.zoomed ?? tab.splitTree.root {
                TerminalSplitSubtreeView(
                    node: node,
                    isRoot: node == tab.splitTree.root,
                    isSplit: tab.splitTree.isSplit,
                    isTabActive: isTabActive,
                    isResizing: isResizing,
                    focusedSurfaceId: tab.focusedSurfaceId,
                    appearance: appearance,
                    tabId: tab.id,
                    notificationStore: notificationStore,
                    onFocus: { tab.focusSurface($0) },
                    onTriggerFlash: { tab.triggerDebugFlash(surfaceId: $0) },
                    onResize: { tab.updateSplitRatio(node: $0, ratio: $1) },
                    onEqualize: { tab.equalizeSplits() }
                )
                .id(node.structuralIdentity)
            }
        }
        .frame(
            width: shouldFreeze ? lastActiveSize.width : nil,
            height: shouldFreeze ? lastActiveSize.height : nil
        )
        .frame(
            maxWidth: shouldFreeze ? nil : .infinity,
            maxHeight: shouldFreeze ? nil : .infinity
        )
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear {
                    updateSize(proxy.size, isActive: isTabActive, isResizing: isResizing)
                }
                .onChange(of: proxy.size) { size in
                    updateSize(size, isActive: isTabActive, isResizing: isResizing)
                }
                .onChange(of: isTabActive) { isActive in
                    if isActive {
                        updateSize(proxy.size, isActive: true, isResizing: isResizing)
                    }
                }
                .onChange(of: isResizing) { nowResizing in
                    if !nowResizing, isTabActive {
                        updateSize(proxy.size, isActive: true, isResizing: false)
                    }
                }
        })
    }

    private func updateSize(_ size: CGSize, isActive: Bool, isResizing: Bool) {
        guard size.width > 0, size.height > 0 else { return }
        if isActive && !isResizing {
            if lastActiveSize != size {
                lastActiveSize = size
            }
            tab.updateSplitViewSize(size)
        } else if lastActiveSize == .zero {
            lastActiveSize = size
        }
    }
}

fileprivate struct TerminalSplitSubtreeView: View {
    let node: SplitTree<TerminalSurface>.Node
    let isRoot: Bool
    let isSplit: Bool
    let isTabActive: Bool
    let isResizing: Bool
    let focusedSurfaceId: UUID?
    let appearance: SplitAppearance
    let tabId: UUID
    let notificationStore: TerminalNotificationStore
    let onFocus: (UUID) -> Void
    let onTriggerFlash: (UUID) -> Void
    let onResize: (SplitTree<TerminalSurface>.Node, Double) -> Void
    let onEqualize: () -> Void

    var body: some View {
        switch node {
        case .leaf(let surface):
            let isFocused = isTabActive && focusedSurfaceId == surface.id
            TerminalSurfaceView(
                surface: surface,
                isFocused: isFocused,
                isSplit: isSplit,
                isResizing: isResizing,
                appearance: appearance,
                tabId: tabId,
                notificationStore: notificationStore,
                onFocus: { onFocus(surface.id) },
                onTriggerFlash: { onTriggerFlash(surface.id) }
            )
        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                .init(get: {
                    CGFloat(split.ratio)
                }, set: {
                    onResize(node, Double($0))
                }),
                dividerColor: appearance.dividerColor,
                resizeIncrements: .init(width: 1, height: 1),
                left: {
                    TerminalSplitSubtreeView(
                        node: split.left,
                        isRoot: false,
                        isSplit: isSplit,
                        isTabActive: isTabActive,
                        isResizing: isResizing,
                        focusedSurfaceId: focusedSurfaceId,
                        appearance: appearance,
                        tabId: tabId,
                        notificationStore: notificationStore,
                        onFocus: onFocus,
                        onTriggerFlash: onTriggerFlash,
                        onResize: onResize,
                        onEqualize: onEqualize
                    )
                },
                right: {
                    TerminalSplitSubtreeView(
                        node: split.right,
                        isRoot: false,
                        isSplit: isSplit,
                        isTabActive: isTabActive,
                        isResizing: isResizing,
                        focusedSurfaceId: focusedSurfaceId,
                        appearance: appearance,
                        tabId: tabId,
                        notificationStore: notificationStore,
                        onFocus: onFocus,
                        onTriggerFlash: onTriggerFlash,
                        onResize: onResize,
                        onEqualize: onEqualize
                    )
                },
                onEqualize: {
                    onEqualize()
                }
            )
        }
    }
}

private struct SplitAppearance {
    let dividerColor: Color
    let unfocusedOverlayColor: Color
    let unfocusedOverlayOpacity: Double
}

private struct TerminalSurfaceView: View {
    @ObservedObject var surface: TerminalSurface
    let isFocused: Bool
    let isSplit: Bool
    let isResizing: Bool
    let appearance: SplitAppearance
    let tabId: UUID
    let notificationStore: TerminalNotificationStore
    let onFocus: () -> Void
    let onTriggerFlash: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            GhosttyTerminalView(
                terminalSurface: surface,
                isActive: isFocused,
                isResizing: isResizing,
                onFocus: { _ in onFocus() },
                onTriggerFlash: onTriggerFlash
            )
            .background(Color.clear)

            if isSplit && !isFocused && appearance.unfocusedOverlayOpacity > 0 {
                Rectangle()
                    .fill(appearance.unfocusedOverlayColor)
                    .opacity(appearance.unfocusedOverlayOpacity)
                    .allowsHitTesting(false)
            }

            if notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: surface.id) {
                Rectangle()
                    .stroke(Color(nsColor: .systemBlue), lineWidth: 2.5)
                    .shadow(color: Color(nsColor: .systemBlue).opacity(0.35), radius: 3)
                    .padding(2)
                    .allowsHitTesting(false)
            }

            if let searchState = surface.searchState {
                SurfaceSearchOverlay(
                    surface: surface,
                    searchState: searchState,
                    onClose: {
                        surface.searchState = nil
                        surface.hostedView.moveFocus()
                    }
                )
            }

            if surface.showCmuxdOverlay {
                SurfaceConnectionOverlay(
                    title: "Connecting to cmuxd…",
                    message: "Starting a remote PTY session."
                )
            } else if let error = surface.cmuxdState.errorMessage {
                SurfaceConnectionErrorOverlay(
                    title: "cmuxd connection failed",
                    message: error,
                    onRetry: { surface.retryCmuxd() }
                )
            }
        }
    }
}

private struct SurfaceConnectionOverlay: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }
}

private struct SurfaceConnectionErrorOverlay: View {
    let title: String
    let message: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("Retry") {
                onRetry()
            }
            .keyboardShortcut(.defaultAction)
            Button("Copy Error") {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString("\(title)\n\(message)", forType: .string)
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
