import Bonsplit
import SwiftUI

struct SurfaceSearchOverlay: View {
    let tabId: UUID
    let surfaceId: UUID
    @ObservedObject var searchState: TerminalSurface.SearchState
    let onMoveFocusToTerminal: () -> Void
    let onNavigateSearch: (_ action: String) -> Void
    let onClose: () -> Void
    @State private var corner: Corner = .topRight
    @State private var dragOffset: CGSize = .zero
    @State private var barSize: CGSize = .zero
    @FocusState private var isSearchFieldFocused: Bool

    private let padding: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                TextField("Search", text: $searchState.needle)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                    .padding(.leading, 8)
                    .padding(.trailing, 50)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.1))
                    .cornerRadius(6)
                    .focused($isSearchFieldFocused)
                    .overlay(alignment: .trailing) {
                    if let selected = searchState.selected {
                        let totalText = searchState.total.map { String($0) } ?? "?"
                        Text("\(selected + 1)/\(totalText)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .padding(.trailing, 8)
                    } else if let total = searchState.total {
                        Text("-/\(total)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .padding(.trailing, 8)
                    }
                }
                .onExitCommand {
                    if searchState.needle.isEmpty {
                        onClose()
                    } else {
                        onMoveFocusToTerminal()
                    }
                }
                .backport.onKeyPress(.return) { modifiers in
                    let action = modifiers.contains(.shift)
                    ? "navigate_search:previous"
                    : "navigate_search:next"
                    onNavigateSearch(action)
                    return .handled
                }

                Button(action: {
                    #if DEBUG
                    dlog("findbar.next surface=\(surfaceId.uuidString.prefix(5))")
                    #endif
                    onNavigateSearch("navigate_search:next")
                }) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(SearchButtonStyle())
                .help("Next match (Return)")

                Button(action: {
                    #if DEBUG
                    dlog("findbar.prev surface=\(surfaceId.uuidString.prefix(5))")
                    #endif
                    onNavigateSearch("navigate_search:previous")
                }) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(SearchButtonStyle())
                .help("Previous match (Shift+Return)")

                Button(action: {
                    #if DEBUG
                    dlog("findbar.close surface=\(surfaceId.uuidString.prefix(5))")
                    #endif
                    onClose()
                }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(SearchButtonStyle())
                .help("Close (Esc)")
            }
            .padding(8)
            .background(.background)
            .clipShape(clipShape)
            .shadow(radius: 4)
            .onAppear {
                NSLog("Find: overlay appear tab=%@ surface=%@", tabId.uuidString, surfaceId.uuidString)
                isSearchFieldFocused = true
            }
            .onReceive(NotificationCenter.default.publisher(for: .ghosttySearchFocus)) { notification in
                guard let focusedSurface = notification.object as? TerminalSurface,
                      focusedSurface.id == surfaceId else { return }
                NSLog("Find: overlay focus tab=%@ surface=%@", tabId.uuidString, surfaceId.uuidString)
                DispatchQueue.main.async {
                    isSearchFieldFocused = true
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
        RoundedRectangle(cornerRadius: 8)
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

struct SearchButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(isHovered || configuration.isPressed ? .primary : .secondary)
            .padding(.horizontal, 2)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .onHover { hovering in
                isHovered = hovering
            }
            .backport.pointerStyle(.link)
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if isPressed {
            return Color.primary.opacity(0.2)
        }
        if isHovered {
            return Color.primary.opacity(0.1)
        }
        return Color.clear
    }
}
