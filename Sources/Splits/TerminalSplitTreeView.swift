import SwiftUI

struct TerminalSplitTreeView: View {
    @ObservedObject var tab: Tab
    let isTabActive: Bool
    @State private var config = GhosttyConfig.load()

    var body: some View {
        let appearance = SplitAppearance(
            dividerColor: Color(nsColor: config.resolvedSplitDividerColor),
            unfocusedOverlayColor: Color(nsColor: config.unfocusedSplitOverlayFill),
            unfocusedOverlayOpacity: config.unfocusedSplitOverlayOpacity
        )
        Group {
            if let node = tab.splitTree.zoomed ?? tab.splitTree.root {
                TerminalSplitSubtreeView(
                    node: node,
                    isRoot: node == tab.splitTree.root,
                    isSplit: tab.splitTree.isSplit,
                    isTabActive: isTabActive,
                    focusedSurfaceId: tab.focusedSurfaceId,
                    appearance: appearance,
                    onFocus: { tab.focusSurface($0) },
                    onResize: { tab.updateSplitRatio(node: $0, ratio: $1) },
                    onEqualize: { tab.equalizeSplits() }
                )
                .id(node.structuralIdentity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { tab.updateSplitViewSize(proxy.size) }
                .onChange(of: proxy.size) { tab.updateSplitViewSize($0) }
        })
    }
}

fileprivate struct TerminalSplitSubtreeView: View {
    let node: SplitTree<TerminalSurface>.Node
    let isRoot: Bool
    let isSplit: Bool
    let isTabActive: Bool
    let focusedSurfaceId: UUID?
    let appearance: SplitAppearance
    let onFocus: (UUID) -> Void
    let onResize: (SplitTree<TerminalSurface>.Node, Double) -> Void
    let onEqualize: () -> Void

    var body: some View {
        switch node {
        case .leaf(let surface):
            let isFocused = isTabActive && focusedSurfaceId == surface.id
            ZStack {
                GhosttyTerminalView(
                    terminalSurface: surface,
                    isActive: isFocused,
                    onFocus: { _ in onFocus(surface.id) }
                )
                .background(Color.clear)

                if isSplit && !isFocused && appearance.unfocusedOverlayOpacity > 0 {
                    Rectangle()
                        .fill(appearance.unfocusedOverlayColor)
                        .opacity(appearance.unfocusedOverlayOpacity)
                        .allowsHitTesting(false)
                }
            }
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
                        focusedSurfaceId: focusedSurfaceId,
                        appearance: appearance,
                        onFocus: onFocus,
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
                        focusedSurfaceId: focusedSurfaceId,
                        appearance: appearance,
                        onFocus: onFocus,
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
