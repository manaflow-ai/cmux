import Bonsplit
import SwiftUI

struct BrowserSearchOverlay: View {
    let panelId: UUID
    @ObservedObject var searchState: BrowserSearchState
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    @State private var corner: Corner = .topRight
    @State private var dragOffset: CGSize = .zero
    @State private var barSize: CGSize = .zero
    @FocusState private var isSearchFieldFocused: Bool
    @AppStorage(UIZoomMetrics.appStorageKey) private var uiZoomScale = UIZoomMetrics.defaultScale

    private var padding: CGFloat { UIZoomMetrics.searchContainerPadding(uiZoomScale) }

    private func requestSearchFieldFocus(maxAttempts: Int = 3) {
        guard maxAttempts > 0 else { return }
        isSearchFieldFocused = true
        guard maxAttempts > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            requestSearchFieldFocus(maxAttempts: maxAttempts - 1)
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: UIZoomMetrics.searchSpacing(uiZoomScale)) {
                TextField(String(localized: "browserSearchOverlay.search", defaultValue: "Search"), text: $searchState.needle)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("BrowserFindSearchTextField")
                    .frame(width: UIZoomMetrics.searchFieldWidth(uiZoomScale))
                    .padding(.leading, UIZoomMetrics.searchFieldLPadding(uiZoomScale))
                    .padding(.trailing, UIZoomMetrics.searchFieldRPadding(uiZoomScale))
                    .padding(.vertical, UIZoomMetrics.searchFieldVPadding(uiZoomScale))
                    .background(Color.primary.opacity(0.1))
                    .cornerRadius(UIZoomMetrics.searchFieldCornerRadius(uiZoomScale))
                    .focused($isSearchFieldFocused)
                    .overlay(alignment: .trailing) {
                    if let selected = searchState.selected {
                        let totalText = searchState.total.map { String($0) } ?? "?"
                        Text("\(selected + 1)/\(totalText)")
                            .font(.system(size: UIZoomMetrics.searchCounterFontSize(uiZoomScale)))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .padding(.trailing, UIZoomMetrics.searchCounterTrailingPadding(uiZoomScale))
                    } else if let total = searchState.total {
                        Text(total == 0 ? "0/0" : "-/\(total)")
                            .font(.system(size: UIZoomMetrics.searchCounterFontSize(uiZoomScale)))
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .padding(.trailing, UIZoomMetrics.searchCounterTrailingPadding(uiZoomScale))
                    }
                }
                .onExitCommand {
                    onClose()
                }
                .onSubmit {
                    // onSubmit fires only after IME composition is committed.
                    if NSEvent.modifierFlags.contains(.shift) {
                        onPrevious()
                    } else {
                        onNext()
                    }
                }

                Button(action: {
                    #if DEBUG
                    dlog("browser.findbar.next panel=\(panelId.uuidString.prefix(5))")
                    #endif
                    onNext()
                }) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(SearchButtonStyle())
                .safeHelp("Next match (Return)")

                Button(action: {
                    #if DEBUG
                    dlog("browser.findbar.prev panel=\(panelId.uuidString.prefix(5))")
                    #endif
                    onPrevious()
                }) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(SearchButtonStyle())
                .safeHelp("Previous match (Shift+Return)")

                Button(action: {
                    #if DEBUG
                    dlog("browser.findbar.close panel=\(panelId.uuidString.prefix(5))")
                    #endif
                    onClose()
                }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(SearchButtonStyle())
                .safeHelp("Close (Esc)")
            }
            .padding(UIZoomMetrics.searchContainerPadding(uiZoomScale))
            .background(.background)
            .clipShape(clipShape)
            .shadow(radius: 4)
            .onAppear {
                #if DEBUG
                dlog("browser.findbar.appear panel=\(panelId.uuidString.prefix(5))")
                #endif
                requestSearchFieldFocus()
            }
            .onReceive(NotificationCenter.default.publisher(for: .browserSearchFocus)) { notification in
                guard let notifiedPanelId = notification.object as? UUID,
                      notifiedPanelId == panelId else { return }
                DispatchQueue.main.async {
                    requestSearchFieldFocus()
                }
            }
            .background(
                GeometryReader { barGeo in
                    Color.clear.onAppear {
                        barSize = barGeo.size
                    }
                }
            )
            .padding(padding)
            .offset(dragOffset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: corner.alignment)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        dragOffset = value.translation
                    }
                    .onEnded { value in
                        let centerPos = centerPosition(for: corner, in: geo.size, barSize: barSize)
                        let newCenter = CGPoint(
                            x: centerPos.x + value.translation.width,
                            y: centerPos.y + value.translation.height
                        )
                        let newCorner = closestCorner(to: newCenter, in: geo.size)
                        withAnimation(.easeOut(duration: 0.2)) {
                            corner = newCorner
                            dragOffset = .zero
                        }
                    }
            )
        }
    }

    private var clipShape: some Shape {
        RoundedRectangle(cornerRadius: UIZoomMetrics.searchContainerCornerRadius(uiZoomScale))
    }

    enum Corner {
        case topLeft
        case topRight
        case bottomLeft
        case bottomRight

        var alignment: Alignment {
            switch self {
            case .topLeft: return .topLeading
            case .topRight: return .topTrailing
            case .bottomLeft: return .bottomLeading
            case .bottomRight: return .bottomTrailing
            }
        }
    }

    private func centerPosition(for corner: Corner, in containerSize: CGSize, barSize: CGSize) -> CGPoint {
        let halfWidth = barSize.width / 2 + padding
        let halfHeight = barSize.height / 2 + padding

        switch corner {
        case .topLeft:
            return CGPoint(x: halfWidth, y: halfHeight)
        case .topRight:
            return CGPoint(x: containerSize.width - halfWidth, y: halfHeight)
        case .bottomLeft:
            return CGPoint(x: halfWidth, y: containerSize.height - halfHeight)
        case .bottomRight:
            return CGPoint(x: containerSize.width - halfWidth, y: containerSize.height - halfHeight)
        }
    }

    private func closestCorner(to point: CGPoint, in containerSize: CGSize) -> Corner {
        let midX = containerSize.width / 2
        let midY = containerSize.height / 2

        if point.x < midX {
            return point.y < midY ? .topLeft : .bottomLeft
        }
        return point.y < midY ? .topRight : .bottomRight
    }
}
