import Bonsplit
import SwiftUI

struct SurfaceSearchOverlay: View {
    let surface: TerminalSurface
    @ObservedObject var searchState: TerminalSurface.SearchState
    let onClose: () -> Void
    @FocusState private var isSearchFieldFocused: Bool

    var body: some View {
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
                .backport.onKeyPress(.return) { modifiers in
                    let action = modifiers.contains(.shift)
                    ? "navigate_search:previous"
                    : "navigate_search:next"
                    _ = surface.performBindingAction(action)
                    return .handled
                }

            Button(action: {
                #if DEBUG
                dlog("findbar.next surface=\(surface.id.uuidString.prefix(5))")
                #endif
                _ = surface.performBindingAction("navigate_search:next")
            }) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(SearchButtonStyle())
            .help("Next match (Return)")

            Button(action: {
                #if DEBUG
                dlog("findbar.prev surface=\(surface.id.uuidString.prefix(5))")
                #endif
                _ = surface.performBindingAction("navigate_search:previous")
            }) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(SearchButtonStyle())
            .help("Previous match (Shift+Return)")

            Button(action: {
                #if DEBUG
                dlog("findbar.close surface=\(surface.id.uuidString.prefix(5))")
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
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 4)
        .onExitCommand {
            if searchState.needle.isEmpty {
                onClose()
            } else {
                surface.hostedView.moveFocus()
            }
        }
        .onAppear {
            NSLog("Find: overlay appear tab=%@ surface=%@", surface.tabId.uuidString, surface.id.uuidString)
#if DEBUG
            dlog("FindDebug: terminal.findbar.appear tab=\(surface.tabId.uuidString) surface=\(surface.id.uuidString)")
#endif
            isSearchFieldFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttySearchFocus)) { notification in
            guard notification.object as? TerminalSurface === surface else { return }
            NSLog("Find: overlay focus tab=%@ surface=%@", surface.tabId.uuidString, surface.id.uuidString)
#if DEBUG
            dlog("FindDebug: terminal.findbar.focus tab=\(surface.tabId.uuidString) surface=\(surface.id.uuidString)")
#endif
            DispatchQueue.main.async {
                isSearchFieldFocused = true
            }
        }
        .transition(.move(edge: .top).combined(with: .opacity))
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
