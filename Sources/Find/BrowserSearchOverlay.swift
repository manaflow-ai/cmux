import AppKit
import ObjectiveC
import SwiftUI

private var cmuxBrowserSearchOverlayPanelIdKey: UInt8 = 0
private var cmuxBrowserSearchOverlayWindowActivePanelIdKey: UInt8 = 0

func setBrowserSearchOverlayPanelId(_ panelId: UUID, on view: NSView) {
    objc_setAssociatedObject(
        view,
        &cmuxBrowserSearchOverlayPanelIdKey,
        panelId,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

private func setActiveBrowserSearchOverlayPanelId(_ panelId: UUID?, on window: NSWindow?) {
    guard let window else { return }
    objc_setAssociatedObject(
        window,
        &cmuxBrowserSearchOverlayWindowActivePanelIdKey,
        panelId,
        .OBJC_ASSOCIATION_RETAIN_NONATOMIC
    )
}

private func activeBrowserSearchOverlayPanelId(on window: NSWindow?) -> UUID? {
    guard let window else { return nil }
    return objc_getAssociatedObject(
        window,
        &cmuxBrowserSearchOverlayWindowActivePanelIdKey
    ) as? UUID
}

private func clearActiveBrowserSearchOverlayPanelId(_ panelId: UUID, on window: NSWindow?) {
    guard activeBrowserSearchOverlayPanelId(on: window) == panelId else { return }
    setActiveBrowserSearchOverlayPanelId(nil, on: window)
}

private func browserSearchOverlayPanelId(from view: NSView?) -> UUID? {
    var current = view
    while let view = current {
        if let panelId = objc_getAssociatedObject(view, &cmuxBrowserSearchOverlayPanelIdKey) as? UUID {
            return panelId
        }
        current = view.superview
    }
    return nil
}

func browserSearchOverlayPanelId(for responder: NSResponder?) -> UUID? {
    guard let responder else { return nil }
    if let editor = responder as? NSTextView,
       editor.isFieldEditor {
        return browserSearchOverlayPanelId(from: editor) ??
            browserSearchOverlayPanelId(from: editor.delegate as? NSView) ??
            activeBrowserSearchOverlayPanelId(on: editor.window)
    }
    return browserSearchOverlayPanelId(from: responder as? NSView)
}

struct BrowserSearchOverlay: View {
    let panelId: UUID
    @ObservedObject var searchState: BrowserSearchState
    let focusRequestId: UUID?
    let canApplyFocusRequest: (UUID) -> Bool
    let onNext: () -> Void
    let onPrevious: () -> Void
    let onClose: () -> Void
    let onFieldMounted: (UUID?) -> Void
    let onFieldDidFocus: (UUID?) -> Void
    let onFieldDidEndEditing: (UUID?) -> Void
    let onDisappear: () -> Void
    @State private var corner: Corner = .topRight
    @State private var dragOffset: CGSize = .zero
    @State private var barSize: CGSize = .zero

    private let padding: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                BrowserSearchTextFieldRepresentable(
                    text: $searchState.needle,
                    panelId: panelId,
                    focusRequestId: focusRequestId,
                    canApplyFocusRequest: canApplyFocusRequest,
                    onFieldMounted: onFieldMounted,
                    onFieldDidFocus: onFieldDidFocus,
                    onEscape: onClose,
                    onReturn: { isShift in
                        if isShift {
                            onPrevious()
                        } else {
                            onNext()
                        }
                    },
                    onFieldDidEndEditing: onFieldDidEndEditing
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
                    onNext()
                }) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(SearchButtonStyle())
                .safeHelp("Next match (Return)")

                Button(action: {
                    onPrevious()
                }) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(SearchButtonStyle())
                .safeHelp("Previous match (Shift+Return)")

                Button(action: {
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
        .onDisappear(perform: onDisappear)
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
    var onWindowAttachment: ((BrowserSearchNativeTextField) -> Void)?

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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onWindowAttachment?(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        if flags.contains(.command) {
            if AppDelegate.shared?.handlePaneFocusNavigationCommandEvent(
                event,
                preferredWindow: window,
                source: "browserFindTextField"
            ) == true {
                return true
            }
            if AppDelegate.shared?.handleBrowserSearchOverlayCommandEvent(
                event,
                preferredWindow: window
            ) == true {
                return true
            }
            if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

private struct BrowserSearchTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    let panelId: UUID
    let focusRequestId: UUID?
    let canApplyFocusRequest: (UUID) -> Bool
    let onFieldMounted: (UUID?) -> Void
    let onFieldDidFocus: (UUID?) -> Void
    let onEscape: () -> Void
    let onReturn: (_ isShift: Bool) -> Void
    let onFieldDidEndEditing: (UUID?) -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: BrowserSearchTextFieldRepresentable
        var isProgrammaticMutation = false
        weak var parentField: BrowserSearchNativeTextField?
        var pendingFocusRequest: Bool?
        var activeFocusRequestId: UUID?

        init(parent: BrowserSearchTextFieldRepresentable) {
            self.parent = parent
        }

        private func markFieldEditor(_ editor: NSTextView?) {
            guard let editor else { return }
            setBrowserSearchOverlayPanelId(parent.panelId, on: editor)
            setActiveBrowserSearchOverlayPanelId(parent.panelId, on: editor.window)
        }

        func focusField(_ field: BrowserSearchNativeTextField, in window: NSWindow, requestId: UUID?) {
            let before = window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let focused = window.makeFirstResponder(field)
#if DEBUG
            dlog(
                "browser.focus.find.fieldFocus panel=\(parent.panelId.uuidString.prefix(5)) " +
                "request=\((requestId ?? parent.focusRequestId)?.uuidString.prefix(8) ?? "nil") " +
                "result=\(focused ? 1 : 0) before=\(before) " +
                "after=\(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
            )
#endif
            guard focused else { return }
            activeFocusRequestId = requestId ?? parent.focusRequestId
            setBrowserSearchOverlayPanelId(parent.panelId, on: field)
            setActiveBrowserSearchOverlayPanelId(parent.panelId, on: window)
            parent.onFieldDidFocus(activeFocusRequestId)
            DispatchQueue.main.async { [weak field] in
                guard let field,
                      let editor = field.currentEditor() as? NSTextView else { return }
                self.markFieldEditor(editor)
                let end = field.stringValue.utf16.count
                editor.setSelectedRange(NSRange(location: end, length: 0))
            }
        }

        func requestFocusIfNeeded(for field: BrowserSearchNativeTextField) {
            guard let requestId = parent.focusRequestId,
                  parent.canApplyFocusRequest(requestId),
                  let window = field.window else {
#if DEBUG
                dlog(
                    "browser.focus.find.fieldFocus.skip panel=\(parent.panelId.uuidString.prefix(5)) " +
                    "request=\(parent.focusRequestId?.uuidString.prefix(8) ?? "nil") " +
                    "reason=not_applicable"
                )
#endif
                return
            }

            let fr = window.firstResponder
            let isFirstResponder =
                fr === field ||
                field.currentEditor() != nil ||
                ((fr as? NSTextView)?.delegate as? NSTextField) === field
            guard !isFirstResponder, pendingFocusRequest != true else {
#if DEBUG
                dlog(
                    "browser.focus.find.fieldFocus.skip panel=\(parent.panelId.uuidString.prefix(5)) " +
                    "request=\(requestId.uuidString.prefix(8)) reason=\(isFirstResponder ? "already_focused" : "pending") " +
                    "fr=\(fr.map { String(describing: type(of: $0)) } ?? "nil")"
                )
#endif
                return
            }

            pendingFocusRequest = true
            DispatchQueue.main.async { [weak field, weak self] in
                guard let self else { return }
                self.pendingFocusRequest = nil
                guard let requestId = self.parent.focusRequestId,
                      self.parent.canApplyFocusRequest(requestId),
                      let field,
                      let window = field.window else { return }
                let fr = window.firstResponder
                let alreadyFocused =
                    fr === field ||
                    field.currentEditor() != nil ||
                    ((fr as? NSTextView)?.delegate as? NSTextField) === field
                guard !alreadyFocused else {
#if DEBUG
                    dlog(
                        "browser.focus.find.fieldFocus.skip panel=\(self.parent.panelId.uuidString.prefix(5)) " +
                        "request=\(requestId.uuidString.prefix(8)) reason=already_focused_async " +
                        "fr=\(fr.map { String(describing: type(of: $0)) } ?? "nil")"
                    )
#endif
                    return
                }
                self.focusField(field, in: window, requestId: requestId)
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            activeFocusRequestId = parent.focusRequestId ?? activeFocusRequestId
            if let field = obj.object as? NSTextField {
                setActiveBrowserSearchOverlayPanelId(parent.panelId, on: field.window)
                markFieldEditor(field.currentEditor() as? NSTextView)
            }
#if DEBUG
            let window = (obj.object as? NSView)?.window
            dlog(
                "browser.focus.find.fieldBeginEditing panel=\(parent.panelId.uuidString.prefix(5)) " +
                "request=\((activeFocusRequestId ?? parent.focusRequestId)?.uuidString.prefix(8) ?? "nil") " +
                "fr=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
            )
#endif
            parent.onFieldDidFocus(activeFocusRequestId ?? parent.focusRequestId)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            let requestId = activeFocusRequestId ?? parent.focusRequestId
#if DEBUG
            let window = (obj.object as? NSView)?.window
            dlog(
                "browser.focus.find.fieldEndEditing panel=\(parent.panelId.uuidString.prefix(5)) " +
                "request=\(requestId?.uuidString.prefix(8) ?? "nil") " +
                "fr=\(window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
            )
#endif
            clearActiveBrowserSearchOverlayPanelId(parent.panelId, on: (obj.object as? NSView)?.window)
            parent.onFieldDidEndEditing(requestId)
            activeFocusRequestId = nil
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            markFieldEditor(textView)
            if let event = NSApp.currentEvent,
               event.type == .keyDown,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                if AppDelegate.shared?.handlePaneFocusNavigationCommandEvent(
                    event,
                    preferredWindow: textView.window,
                    source: "browserFindFieldEditor"
                ) == true {
                    return true
                }
                if AppDelegate.shared?.handleBrowserSearchOverlayCommandEvent(
                    event,
                    preferredWindow: textView.window
                ) == true {
                    return true
                }
                if AppDelegate.shared?.handleBrowserSurfaceKeyEquivalent(event) == true {
                    return true
                }
            }

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
        field.identifier = NSUserInterfaceItemIdentifier("BrowserFindSearchTextField")
        field.setAccessibilityIdentifier("BrowserFindSearchTextField")
        field.delegate = context.coordinator
        field.target = nil
        field.action = nil
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.stringValue = text
        field.onWindowAttachment = { [weak coordinator = context.coordinator] attachedField in
            guard let coordinator else { return }
            coordinator.parent.onFieldMounted(coordinator.parent.focusRequestId)
            coordinator.requestFocusIfNeeded(for: attachedField)
        }
        setBrowserSearchOverlayPanelId(panelId, on: field)
        context.coordinator.parentField = field
        return field
    }

    func updateNSView(_ nsView: BrowserSearchNativeTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.parentField = nsView
        setBrowserSearchOverlayPanelId(panelId, on: nsView)

        if let editor = nsView.currentEditor() as? NSTextView {
            setActiveBrowserSearchOverlayPanelId(panelId, on: nsView.window)
            setBrowserSearchOverlayPanelId(panelId, on: editor)
            if editor.string != text, !editor.hasMarkedText() {
                context.coordinator.isProgrammaticMutation = true
                editor.string = text
                nsView.stringValue = text
                context.coordinator.isProgrammaticMutation = false
            }
        } else if nsView.stringValue != text {
            nsView.stringValue = text
        }

        context.coordinator.requestFocusIfNeeded(for: nsView)
    }

    static func dismantleNSView(_ nsView: BrowserSearchNativeTextField, coordinator: Coordinator) {
        let activeRequestId = coordinator.activeFocusRequestId ?? coordinator.parent.focusRequestId
#if DEBUG
        dlog(
            "browser.focus.find.fieldDismantle panel=\(coordinator.parent.panelId.uuidString.prefix(5)) " +
            "request=\(activeRequestId?.uuidString.prefix(8) ?? "nil") " +
            "fr=\(nsView.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil")"
        )
#endif
        if let activeRequestId {
            coordinator.parent.onFieldDidEndEditing(activeRequestId)
        }
        clearActiveBrowserSearchOverlayPanelId(coordinator.parent.panelId, on: nsView.window)
        nsView.delegate = nil
        nsView.onWindowAttachment = nil
        coordinator.parentField = nil
    }
}
