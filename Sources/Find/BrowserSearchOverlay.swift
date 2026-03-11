import AppKit
import Bonsplit
import SwiftUI

struct BrowserSearchOverlay: View {
    let panelId: UUID
    @ObservedObject var searchState: BrowserSearchState
    let focusRequestGeneration: UInt64
    let canApplyFocusRequest: (UInt64) -> Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onFieldDidFocus: () -> Void
    @State private var corner: Corner = .topRight
    @State private var dragOffset: CGSize = .zero
    @State private var barSize: CGSize = .zero
    @FocusState private var isSearchFieldFocused: Bool

    private let padding: CGFloat = 8

#if DEBUG
    private func debugFirstResponderSummary() -> String {
        guard let window = NSApp.keyWindow else { return "nil" }
        guard let firstResponder = window.firstResponder else { return "nil" }
        if let editor = firstResponder as? NSTextView, editor.isFieldEditor {
            let delegateSummary = editor.delegate.map { String(describing: type(of: $0)) } ?? "nil"
            return "fieldEditor(delegate=\(delegateSummary))"
        }
        return String(describing: type(of: firstResponder))
    }
#endif

    private func logFocusState(_ event: String) {
#if DEBUG
        let keyWindow = NSApp.keyWindow
        dlog(
            "browser.findbar.focus panel=\(panelId.uuidString.prefix(5)) " +
            "event=\(event) keyWindow=\(keyWindow?.windowNumber ?? -1) " +
            "firstResponder=\(debugFirstResponderSummary()) " +
            "focused=\(isSearchFieldFocused ? 1 : 0)"
        )
#endif
    }

    private func requestSearchFieldFocus(maxAttempts: Int = 3, origin: String) {
        guard maxAttempts > 0 else { return }
        guard canApplyFocusRequest(focusRequestGeneration) else {
#if DEBUG
            logFocusState("request.skip origin=\(origin) generation=\(focusRequestGeneration)")
#endif
            return
        }
        logFocusState("request.begin origin=\(origin) remaining=\(maxAttempts)")
        isSearchFieldFocused = true
#if DEBUG
        DispatchQueue.main.async {
            guard canApplyFocusRequest(focusRequestGeneration) else {
                logFocusState("request.skipAsync origin=\(origin) generation=\(focusRequestGeneration)")
                return
            }
            logFocusState("request.afterAsync origin=\(origin) remaining=\(maxAttempts)")
        }
#endif
        guard maxAttempts > 1 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard canApplyFocusRequest(focusRequestGeneration) else {
#if DEBUG
                logFocusState("request.skipRetry origin=\(origin) generation=\(focusRequestGeneration)")
#endif
                return
            }
            requestSearchFieldFocus(maxAttempts: maxAttempts - 1, origin: origin)
        }
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                TextField("Search", text: $searchState.needle)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("BrowserFindSearchTextField")
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
                        Text(total == 0 ? "0/0" : "-/\(total)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .padding(.trailing, 8)
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
            .padding(8)
            .background(.background)
            .clipShape(clipShape)
            .shadow(radius: 4)
            .onAppear {
#if DEBUG
                dlog("browser.findbar.appear panel=\(panelId.uuidString.prefix(5))")
#endif
                logFocusState("appear")
                requestSearchFieldFocus(origin: "appear")
            }
            .onChange(of: isSearchFieldFocused) { _, focused in
                logFocusState("focusState.change next=\(focused ? 1 : 0)")
                if focused {
                    onFieldDidFocus()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .browserSearchFocus)) { notification in
                guard let notifiedPanelId = notification.object as? UUID,
                      notifiedPanelId == panelId else { return }
                logFocusState("notification.received")
                DispatchQueue.main.async {
                    requestSearchFieldFocus(origin: "notification")
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
