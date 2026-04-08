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
    @State private var isSearchFieldFocused: Bool = true

    private let padding: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                BrowserSearchTextFieldRepresentable(
                    text: $searchState.needle,
                    isFocused: $isSearchFieldFocused,
                    panelId: panelId,
                    focusRequestGeneration: focusRequestGeneration,
                    canApplyFocusRequest: canApplyFocusRequest,
                    onFieldDidFocus: onFieldDidFocus,
                    onEscape: onClose,
                    onReturn: { isShift in
                        if isShift {
                            onPrevious()
                        } else {
                            onNext()
                        }
                    }
                )
                    .frame(width: 180)
                    .padding(.leading, 8)
                    .padding(.trailing, 50)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.1))
                    .cornerRadius(6)
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
                isSearchFieldFocused = true
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

private final class BrowserSearchNativeTextField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private struct BrowserSearchTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let panelId: UUID
    let focusRequestGeneration: UInt64
    let canApplyFocusRequest: (UInt64) -> Bool
    let onFieldDidFocus: () -> Void
    let onEscape: () -> Void
    let onReturn: (_ isShift: Bool) -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BrowserSearchTextFieldRepresentable
        var isProgrammaticMutation = false
        weak var parentField: BrowserSearchNativeTextField?
        var pendingFocusRequest: Bool?
        var searchFocusObserver: NSObjectProtocol?

        init(parent: BrowserSearchTextFieldRepresentable) {
            self.parent = parent
        }

        deinit {
            if let searchFocusObserver {
                NotificationCenter.default.removeObserver(searchFocusObserver)
            }
        }

        func focusField(_ field: BrowserSearchNativeTextField, in window: NSWindow) {
            guard window.makeFirstResponder(field) else { return }
            DispatchQueue.main.async { [weak field] in
                guard let field,
                      let editor = field.currentEditor() as? NSTextView else { return }
                let end = field.stringValue.utf16.count
                editor.setSelectedRange(NSRange(location: end, length: 0))
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            parent.onFieldDidFocus()
            if !parent.isFocused {
                DispatchQueue.main.async {
                    self.parent.isFocused = true
                }
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            if parent.isFocused {
                DispatchQueue.main.async {
                    self.parent.isFocused = false
                }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                if textView.hasMarkedText() { return false }
                parent.onEscape()
                return true
            case #selector(NSResponder.insertNewline(_:)):
                if textView.hasMarkedText() { return false }
                let isShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                parent.onReturn(isShift)
                return true
            default:
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> BrowserSearchNativeTextField {
        let field = BrowserSearchNativeTextField(frame: .zero)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = String(localized: "search.placeholder", defaultValue: "Search")
        field.setAccessibilityIdentifier("BrowserFindSearchTextField")
        field.delegate = context.coordinator
        field.target = nil
        field.action = nil
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.stringValue = text
        context.coordinator.parentField = field
        context.coordinator.searchFocusObserver = NotificationCenter.default.addObserver(
            forName: .browserSearchFocus,
            object: nil,
            queue: .main
        ) { [weak field, weak coordinator = context.coordinator] notification in
            guard let field, let coordinator else { return }
            guard let notifiedPanelId = notification.object as? UUID,
                  notifiedPanelId == coordinator.parent.panelId else { return }
            guard coordinator.parent.canApplyFocusRequest(coordinator.parent.focusRequestGeneration) else { return }
            guard let window = field.window else { return }
            let fr = window.firstResponder
            let alreadyFocused = fr === field ||
                field.currentEditor() != nil ||
                ((fr as? NSTextView)?.delegate as? NSTextField) === field
            guard !alreadyFocused else { return }
            coordinator.focusField(field, in: window)
        }
        return field
    }

    func updateNSView(_ nsView: BrowserSearchNativeTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.parentField = nsView

        if let editor = nsView.currentEditor() as? NSTextView {
            if editor.string != text, !editor.hasMarkedText() {
                context.coordinator.isProgrammaticMutation = true
                editor.string = text
                nsView.stringValue = text
                context.coordinator.isProgrammaticMutation = false
            }
        } else if nsView.stringValue != text {
            nsView.stringValue = text
        }

        if let window = nsView.window {
            let fr = window.firstResponder
            let isFirstResponder =
                fr === nsView ||
                nsView.currentEditor() != nil ||
                ((fr as? NSTextView)?.delegate as? NSTextField) === nsView

            if isFocused,
               canApplyFocusRequest(focusRequestGeneration),
               !isFirstResponder,
               context.coordinator.pendingFocusRequest != true {
                context.coordinator.pendingFocusRequest = true
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    coordinator?.pendingFocusRequest = nil
                    guard let coordinator,
                          coordinator.parent.isFocused,
                          coordinator.parent.canApplyFocusRequest(coordinator.parent.focusRequestGeneration) else { return }
                    guard let nsView, let window = nsView.window else { return }
                    let fr = window.firstResponder
                    let alreadyFocused = fr === nsView ||
                        nsView.currentEditor() != nil ||
                        ((fr as? NSTextView)?.delegate as? NSTextField) === nsView
                    guard !alreadyFocused else { return }
                    coordinator.focusField(nsView, in: window)
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: BrowserSearchNativeTextField, coordinator: Coordinator) {
        if let observer = coordinator.searchFocusObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.searchFocusObserver = nil
        }
        nsView.delegate = nil
        coordinator.parentField = nil
    }
}
