import AppKit
import CmuxSwiftRender
import SwiftUI

/// A horizontally split sidebar root.
///
/// Two children keep the original draggable split. Three or more children render
/// as Finder-style fixed-width columns inside a horizontal scroll view. In both
/// modes each column scrolls independently.
struct ResizableHSplit: View {
    let columns: [RenderNode]

    @AppStorage("cmux.customSidebar.splitFraction") private var fraction: Double = 0.5
    @State private var dragStartFraction: Double?
    @Environment(\.customSidebarContentInsets) private var contentInsets

    private let minColumnWidth: CGFloat = 80
    private let maxFinderColumnWidth: CGFloat = 168
    private let handleWidth: CGFloat = 10

    var body: some View {
        if columns.count > 2 {
            multiColumnBody
        } else {
            twoColumnBody
        }
    }

    private var twoColumnBody: some View {
        GeometryReader { geo in
            let total = max(geo.size.width, 1)
            let lowerBound = Double(minColumnWidth / total)
            let clamped = min(max(fraction, lowerBound), max(lowerBound, 1 - lowerBound))
            let leadingWidth = CGFloat(clamped) * total

            HStack(spacing: 0) {
                column(columns.first)
                    .frame(width: leadingWidth)
                divider(total: total)
                column(columns.count > 1 ? columns[1] : nil)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var multiColumnBody: some View {
        GeometryReader { geo in
            let visibleColumns = CGFloat(min(columns.count, 3))
            let dividerWidth = CGFloat(max(columns.count - 1, 0))
            let columnWidth = min(
                maxFinderColumnWidth,
                max(minColumnWidth, floor((geo.size.width - dividerWidth) / visibleColumns))
            )
            ScrollView(.horizontal) {
                HStack(spacing: 0) {
                    ForEach(columns.indices, id: \.self) { index in
                        if index > columns.startIndex {
                            Divider()
                        }
                        column(columns[index])
                            .frame(width: columnWidth)
                    }
                }
                .frame(height: geo.size.height)
            }
        }
    }

    @ViewBuilder
    private func column(_ node: RenderNode?) -> some View {
        if let node {
            ScrollView {
                RenderNodeView(node: node)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(8)
            }
            // Reserve the titlebar-accessory and footer bands so each column's
            // content rests below the chrome and scrolls up into the host's
            // top fade mask instead of underlapping the accessory bar.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: contentInsets.top).allowsHitTesting(false)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear.frame(height: contentInsets.bottom).allowsHitTesting(false)
            }
        } else {
            Color.clear
        }
    }

    private func divider(total: CGFloat) -> some View {
        ZStack {
            Divider()
            Color.clear.frame(width: handleWidth)
        }
        .frame(width: handleWidth)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    let start = dragStartFraction ?? fraction
                    if dragStartFraction == nil { dragStartFraction = start }
                    let newLeading = CGFloat(start) * total + value.translation.width
                    let lower = Double(minColumnWidth / total)
                    fraction = min(max(Double(newLeading / total), lower), 1 - lower)
                }
                .onEnded { _ in dragStartFraction = nil }
        )
    }
}
