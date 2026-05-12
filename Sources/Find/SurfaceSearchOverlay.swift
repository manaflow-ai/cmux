import AppKit
import Bonsplit
import SwiftUI

private extension NSView {
    func cmuxAncestor<T: NSView>(of type: T.Type) -> T? {
        var current: NSView? = self
        while let view = current {
            if let target = view as? T {
                return target
            }
            current = view.superview
        }
        return nil
    }
}

struct SurfaceSearchOverlay: View {
    let tabId: UUID
    let surfaceId: UUID
    @ObservedObject var searchState: TerminalSurface.SearchState
    let canApplyFocusRequest: () -> Bool
    let onNavigateSearch: (_ action: String) -> Void
    let onFieldDidFocus: () -> Void
    let onClose: () -> Void
    @State private var corner: Corner = .topRight
    @State private var dragOffset: CGSize = .zero
    @State private var barSize: CGSize = .zero
    @State private var isSearchFieldFocused: Bool = true

    private let padding: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 4) {
                SearchTextFieldRepresentable(
                    text: $searchState.needle,
                    isFocused: $isSearchFieldFocused,
                    surfaceId: surfaceId,
                    selectionOwner: searchState,
                    canApplyFocusRequest: canApplyFocusRequest,
                    onFieldDidFocus: onFieldDidFocus,
                    onEscape: {
                        #if DEBUG
                        cmuxDebugLog("find.nativeField.escape surface=\(surfaceId.uuidString.prefix(5)) needleEmpty=\(searchState.needle.isEmpty)")
                        #endif
                        onClose()
                    },
                    onReturn: { isShift in
                        let action = isShift
                            ? "navigate_search:previous"
                            : "navigate_search:next"
                        onNavigateSearch(action)
                    }
                )
                .accessibilityIdentifier("TerminalFindSearchTextField")
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
                        Text("-/\(total)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()
                            .padding(.trailing, 8)
                    }
                }

                Button(action: {
                    #if DEBUG
                    cmuxDebugLog("findbar.next surface=\(surfaceId.uuidString.prefix(5))")
                    #endif
                    onNavigateSearch("navigate_search:next")
                }) {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(SearchButtonStyle())
                .safeHelp(String(localized: "search.nextMatch.help", defaultValue: "Next match (Return)"))

                Button(action: {
                    #if DEBUG
                    cmuxDebugLog("findbar.prev surface=\(surfaceId.uuidString.prefix(5))")
                    #endif
                    onNavigateSearch("navigate_search:previous")
                }) {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(SearchButtonStyle())
                .safeHelp(String(localized: "search.previousMatch.help", defaultValue: "Previous match (Shift+Return)"))

                Button(action: {
                    #if DEBUG
                    cmuxDebugLog("findbar.close surface=\(surfaceId.uuidString.prefix(5))")
                    #endif
                    onClose()
                }) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(SearchButtonStyle())
                .safeHelp(String(localized: "search.close.help", defaultValue: "Close (Esc)"))
            }
            .padding(8)
            .background(.background)
            .clipShape(clipShape)
            .shadow(radius: 4)
            .onAppear {
                #if DEBUG
                cmuxDebugLog("find.overlay.appear tab=\(tabId.uuidString.prefix(5)) surface=\(surfaceId.uuidString.prefix(5))")
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

// MARK: - Native Search Text Field (AppKit)

/// NSTextField subclass for the terminal find bar.
/// Strips visual chrome so SwiftUI handles the background/border appearance.
private final class SearchNativeTextField: FindSelectionTrackingTextField {
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

/// NSViewRepresentable wrapping SearchNativeTextField.
/// Handles Escape and Return at the AppKit delegate level, eliminating the
/// SwiftUI @FocusState / AppKit first-responder mismatch that broke focus
/// after window switching.
private struct SearchTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    let surfaceId: UUID
    let selectionOwner: AnyObject
    let canApplyFocusRequest: () -> Bool
    let onFieldDidFocus: () -> Void
    let onEscape: () -> Void
    let onReturn: (_ isShift: Bool) -> Void

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: SearchTextFieldRepresentable
        var isProgrammaticMutation = false
        weak var parentField: SearchNativeTextField?
        var pendingFocusRequest: Bool?
        var searchFocusObserver: NSObjectProtocol?
        var lastSelectedRange: NSRange?

        init(parent: SearchTextFieldRepresentable) {
            self.parent = parent
        }

        deinit {
            if let searchFocusObserver {
                NotificationCenter.default.removeObserver(searchFocusObserver)
            }
        }

        func focusField(_ field: SearchNativeTextField, in window: NSWindow, selectAll: Bool) {
            let alreadyFocused = cmuxTextFieldIsFirstResponder(field, in: window)
            guard alreadyFocused || window.makeFirstResponder(field) else { return }
            let rememberedRange = field.cmuxLastSelectedRange ?? cmuxStoredFindSelection(for: self.parent.selectionOwner) ?? self.lastSelectedRange
            if let selection = cmuxApplyFindFocusSelection(field: field, selectAll: selectAll, alreadyFocused: alreadyFocused, rememberedRange: rememberedRange) { self.lastSelectedRange = selection; return }
            DispatchQueue.main.async { [weak field, weak self] in
                guard let field, let self,
                      let selection = cmuxApplyFindFocusSelection(field: field, selectAll: selectAll, alreadyFocused: alreadyFocused, rememberedRange: rememberedRange) else { return }
                self.lastSelectedRange = selection
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
            rememberSelection(from: field)
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            #if DEBUG
            cmuxDebugLog("find.nativeField.beginEditing surface=\(parent.surfaceId.uuidString.prefix(5))")
            #endif
            parent.onFieldDidFocus()
            if !parent.isFocused {
                DispatchQueue.main.async {
                    self.parent.isFocused = true
                }
            }
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            #if DEBUG
            cmuxDebugLog("find.nativeField.endEditing surface=\(parent.surfaceId.uuidString.prefix(5))")
            #endif
            if let field = obj.object as? NSTextField {
                rememberSelection(from: field)
            }
            if parent.isFocused {
                DispatchQueue.main.async {
                    self.parent.isFocused = false
                }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.cancelOperation(_:)):
                return handleEscape(from: textView, control: control)
            case #selector(NSResponder.insertNewline(_:)):
                if textView.hasMarkedText() { return false }
                rememberSelection(from: textView)
                let isShift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                parent.onReturn(isShift)
                return true
            default:
                if cmuxFindCommandMayChangeSelection(commandSelector) {
                    DispatchQueue.main.async { [weak self, weak textView] in
                        guard let textView else { return }
                        self?.rememberSelection(from: textView)
                    }
                }
                return false
            }
        }

        func handleEscape(from textView: NSTextView, control: NSControl? = nil) -> Bool {
            // Don't intercept Escape during CJK IME composition (issue #118)
            if textView.hasMarkedText() { return false }
            rememberSelection(from: textView)
            (control ?? parentField)?.cmuxAncestor(of: GhosttySurfaceScrollView.self)?.beginFindEscapeSuppression()
            parent.onEscape()
            return true
        }

        private func rememberSelection(from field: NSTextField) {
            if let field = field as? SearchNativeTextField,
               let selection = field.cmuxRememberSelectionFromCurrentEditor() {
                lastSelectedRange = selection
                return
            }
            guard let editor = field.currentEditor() as? NSTextView else { return }
            rememberSelection(from: editor)
        }

        private func rememberSelection(from textView: NSTextView) {
            let selection = cmuxClampedFindSelection(textView.selectedRange(), in: textView.string)
            lastSelectedRange = selection
            parentField?.cmuxLastSelectedRange = selection
            cmuxStoreFindSelection(selection, for: parent.selectionOwner)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> SearchNativeTextField {
        let field = SearchNativeTextField(frame: .zero)
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.placeholderString = String(localized: "search.placeholder", defaultValue: "Search")
        field.setAccessibilityIdentifier("TerminalFindSearchTextField")
        field.delegate = context.coordinator
        field.cmuxSelectionOwner = selectionOwner
        field.cmuxOnEscape = { [weak coordinator = context.coordinator] textView in coordinator?.handleEscape(from: textView) ?? false }
        field.stringValue = text
        context.coordinator.parentField = field

        // Observe .ghosttySearchFocus to immediately focus from AppKit level.
        // This is the primary mechanism for restoring focus after window switches.
        context.coordinator.searchFocusObserver = NotificationCenter.default.addObserver(
            forName: .ghosttySearchFocus,
            object: nil,
            queue: .main
        ) { [weak field, weak coordinator = context.coordinator] notification in
            guard let field, let coordinator else { return }
            guard let surface = notification.object as? TerminalSurface,
                  surface.id == coordinator.parent.surfaceId else { return }
            guard coordinator.parent.canApplyFocusRequest() else { return }
            guard let window = field.window else { return }
            let selectAll = notification.userInfo?[FindFocusNotificationKey.selectAll] as? Bool == true
            // Don't re-focus if already first responder. makeFirstResponder on an
            // already-editing NSTextField ends the editing session and restarts it
            // with all text selected, causing typed characters to replace each other.
            let alreadyFocused = cmuxTextFieldIsFirstResponder(field, in: window)
            #if DEBUG
            cmuxDebugLog(
                "find.nativeField.searchFocusNotification surface=\(coordinator.parent.surfaceId.uuidString.prefix(5)) " +
                "alreadyFocused=\(alreadyFocused) firstResponder=\(String(describing: window.firstResponder))"
            )
            #endif
            guard !alreadyFocused else { return }
            coordinator.focusField(field, in: window, selectAll: selectAll)
#if DEBUG
            cmuxDebugLog(
                "find.nativeField.searchFocusApply surface=\(coordinator.parent.surfaceId.uuidString.prefix(5)) " +
                "selectAll=\(selectAll ? 1 : 0) firstResponder=\(String(describing: window.firstResponder))"
            )
#endif
        }

        return field
    }

    func updateNSView(_ nsView: SearchNativeTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.parentField = nsView
        nsView.delegate = context.coordinator
        nsView.cmuxSelectionOwner = selectionOwner
        nsView.cmuxOnEscape = { [weak coordinator = context.coordinator] textView in coordinator?.handleEscape(from: textView) ?? false }

        // Sync text from binding to field (skip during active IME composition)
        if let editor = nsView.currentEditor() as? NSTextView {
            if editor.string != text, !editor.hasMarkedText() {
                let selectedRange = nsView.cmuxRememberSelection(editor.selectedRange(), in: text)
                context.coordinator.isProgrammaticMutation = true
                editor.string = text
                nsView.stringValue = text
                editor.setSelectedRange(selectedRange)
                context.coordinator.lastSelectedRange = selectedRange
                cmuxStoreFindSelection(selectedRange, for: selectionOwner)
                context.coordinator.isProgrammaticMutation = false
            }
        } else if nsView.stringValue != text {
            nsView.stringValue = text
        }

        // Sync focus from binding to AppKit
        if let window = nsView.window {
            let isFirstResponder = cmuxTextFieldIsFirstResponder(nsView, in: window)

            if isFocused,
               canApplyFocusRequest(),
               !isFirstResponder,
               context.coordinator.pendingFocusRequest != true {
                context.coordinator.pendingFocusRequest = true
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    coordinator?.pendingFocusRequest = nil
                    guard let coordinator,
                          coordinator.parent.isFocused,
                          coordinator.parent.canApplyFocusRequest() else { return }
                    guard let nsView, let window = nsView.window else { return }
                    let alreadyFocused = cmuxTextFieldIsFirstResponder(nsView, in: window)
                    guard !alreadyFocused else { return }
                    coordinator.focusField(nsView, in: window, selectAll: false)
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: SearchNativeTextField, coordinator: Coordinator) {
        if let observer = coordinator.searchFocusObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.searchFocusObserver = nil
        }
        nsView.delegate = nil
        nsView.cmuxSelectionOwner = nil
        nsView.cmuxOnEscape = nil
        coordinator.parentField = nil
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
