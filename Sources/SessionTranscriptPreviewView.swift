import AppKit
import Bonsplit
import CMUXAgentVault
import SQLite3
import SwiftUI
import UniformTypeIdentifiers


// MARK: - Session transcript preview popover
private struct SessionTranscriptPreviewView: View {
    let entry: SessionEntry
    @ObservedObject var sizeModel: SessionTranscriptPopoverSizeModel
    let onResize: (CGSize) -> Void
    let onDismiss: () -> Void

    @State private var loadState: SessionTranscriptPreviewState = .loading
    @State private var closeIsHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: sizeModel.size.width, height: sizeModel.size.height)
        .overlay(alignment: .bottomTrailing) {
            SessionTranscriptResizeHandle(
                size: sizeModel.size,
                onResize: onResize
            )
        }
        .task(id: entry.id) {
            await loadTranscript()
        }
        .background(
            EscapeKeyCatcher { onDismiss() }
        )
    }

    private var header: some View {
        HStack(spacing: 8) {
            AgentIconImage(agent: entry.agent, size: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let cwd = entry.cwdLabel {
                    Text(cwd)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(closeIsHovered ? .primary : .secondary)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(closeIsHovered ? Color.primary.opacity(0.08) : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .onHover { closeIsHovered = $0 }
                .onTapGesture {
                    onDismiss()
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(String(localized: "common.close", defaultValue: "Close")))
                .accessibilityAddTraits(.isButton)
                .help(String(localized: "common.close", defaultValue: "Close"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var content: some View {
        switch loadState {
        case .loading:
            loadingStatusRow
        case .missingFile:
            statusRow(
                systemImage: "doc.badge.questionmark",
                text: String(localized: "sessionIndex.preview.noFile", defaultValue: "No transcript file")
            )
        case .failed:
            statusRow(
                systemImage: "exclamationmark.triangle.fill",
                text: String(localized: "sessionIndex.preview.error", defaultValue: "Couldn't load transcript")
            )
        case .loaded(let turns):
            if turns.isEmpty {
                statusRow(
                    systemImage: "text.bubble",
                    text: String(localized: "sessionIndex.preview.empty", defaultValue: "No previewable messages")
                )
            } else {
                SessionTranscriptVirtualizedList(rows: turns)
            }
        }
    }

    private var loadingStatusRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(String(localized: "sessionIndex.popover.loading", defaultValue: "Loading…"))
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func statusRow(systemImage: String, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.secondary)
            Text(text)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @MainActor
    private func loadTranscript() async {
        loadState = .loading
        do {
            let turns = try await SessionTranscriptLoader.load(entry: entry)
            guard !Task.isCancelled else { return }
            loadState = .loaded(SessionTranscriptDisplayRow.rows(from: turns))
        } catch SessionTranscriptLoadError.missingFile {
            guard !Task.isCancelled else { return }
            loadState = .missingFile
        } catch {
            guard !Task.isCancelled else { return }
            loadState = .failed
        }
    }
}

private enum SessionTranscriptPreviewLayout {
    static let defaultSize = CGSize(width: 520, height: 500)
    static let minSize = CGSize(width: 420, height: 320)
    static let maxSize = CGSize(width: 920, height: 820)

    static func clamped(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(max(size.width, minSize.width), maxSize.width),
            height: min(max(size.height, minSize.height), maxSize.height)
        )
    }
}

private final class SessionTranscriptPopoverSizeModel: ObservableObject {
    @Published var size: CGSize

    init(size: CGSize = SessionTranscriptPreviewLayout.defaultSize) {
        self.size = size
    }
}

private struct SessionTranscriptResizeHandle: View {
    let size: CGSize
    let onResize: (CGSize) -> Void
    @State private var dragStartSize: CGSize?
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ForEach(0..<3, id: \.self) { index in
                Capsule()
                    .fill(Color.secondary.opacity(isHovered ? 0.72 : 0.42))
                    .frame(width: CGFloat(6 + index * 5), height: 1)
                    .offset(x: -4, y: CGFloat(-5 - index * 4))
            }
        }
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let baseSize = dragStartSize ?? size
                    dragStartSize = baseSize
                    onResize(
                        CGSize(
                            width: baseSize.width + value.translation.width,
                            height: baseSize.height + value.translation.height
                        )
                    )
                }
                .onEnded { _ in
                    dragStartSize = nil
                }
        )
        .help(String(localized: "sessionIndex.preview.resize", defaultValue: "Resize preview"))
    }
}

private struct SessionTranscriptVirtualizedList: View, Equatable {
    let rows: [SessionTranscriptDisplayRow]

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    SessionTranscriptTurnView(row: row)
                        .id(row.id)
                }
            }
            .padding(.vertical, 6)
        }
        .background(Color.primary.opacity(0.018))
    }
}

private struct SessionTranscriptTurnView: View, Equatable {
    let row: SessionTranscriptDisplayRow

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 3) {
                Text(row.isContinuation ? "" : row.role.label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(row.role.foregroundColor)
                    .lineLimit(1)
                    .frame(width: 58, alignment: .trailing)
                if row.isContinuation {
                    Circle()
                        .fill(row.role.foregroundColor.opacity(0.38))
                        .frame(width: 3, height: 3)
                }
            }
            Text(row.text)
                .font(row.role.bodyFont)
                .foregroundColor(.primary.opacity(0.92))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(row.role.foregroundColor.opacity(0.46))
                .frame(width: 2)
        }
        .background(row.role.backgroundColor)
    }
}

private struct SessionTranscriptDisplayRow: Identifiable, Equatable {
    let id: String
    let role: SessionTranscriptRole
    let text: String
    let isContinuation: Bool

    private static let chunkCharacterLimit = 5_000

    static func rows(from turns: [SessionTranscriptTurn]) -> [SessionTranscriptDisplayRow] {
        turns.flatMap { turn in
            chunks(for: turn.text).enumerated().map { offset, chunk in
                SessionTranscriptDisplayRow(
                    id: "\(turn.id)-\(offset)",
                    role: turn.role,
                    text: chunk,
                    isContinuation: offset > 0
                )
            }
        }
    }

    private static func chunks(for text: String) -> [String] {
        guard text.count > chunkCharacterLimit else {
            return [text]
        }
        var output: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let rawEnd = text.index(
                start,
                offsetBy: chunkCharacterLimit,
                limitedBy: text.endIndex
            ) ?? text.endIndex
            let end = preferredBreak(in: text, from: start, rawEnd: rawEnd)
            output.append(String(text[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = end
            while start < text.endIndex, text[start].isWhitespace {
                start = text.index(after: start)
            }
        }
        return output.filter { !$0.isEmpty }
    }

    private static func preferredBreak(
        in text: String,
        from start: String.Index,
        rawEnd: String.Index
    ) -> String.Index {
        guard rawEnd < text.endIndex else {
            return text.endIndex
        }
        let searchStart = text.index(
            rawEnd,
            offsetBy: -min(chunkCharacterLimit / 4, text.distance(from: start, to: rawEnd))
        )
        if let newline = text[searchStart..<rawEnd].lastIndex(of: "\n") {
            return text.index(after: newline)
        }
        if let space = text[searchStart..<rawEnd].lastIndex(where: { $0.isWhitespace }) {
            return text.index(after: space)
        }
        return rawEnd
    }
}

private enum SessionTranscriptPreviewState: Equatable {
    case loading
    case missingFile
    case failed
    case loaded([SessionTranscriptDisplayRow])
}

struct SessionTranscriptPopoverHost: NSViewRepresentable {
    @Binding var isPresented: Bool
    let entry: SessionEntry

    func makeCoordinator() -> Coordinator {
        Coordinator(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> PopoverAnchorView {
        let view = PopoverAnchorView()
        view.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.anchorView = view
        view.onDidMoveToWindow = { [weak coordinator = context.coordinator] in
            coordinator?.anchorDidMoveToWindow()
        }
        return view
    }

    func updateNSView(_ nsView: PopoverAnchorView, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchorView = nsView
        coordinator.update(entry: entry)
        if isPresented {
            coordinator.present()
        } else {
            coordinator.dismiss()
        }
    }

    static func dismantleNSView(_ nsView: PopoverAnchorView, coordinator: Coordinator) {
        nsView.onDidMoveToWindow = nil
        coordinator.dismiss()
    }

    final class Coordinator: NSObject, NSPopoverDelegate {
        @Binding var isPresented: Bool
        weak var anchorView: NSView?

        private let hostingController = NSHostingController(rootView: AnyView(EmptyView()))
        private var popover: NSPopover?
        private var currentEntry: SessionEntry?
        private let sizeModel = SessionTranscriptPopoverSizeModel()
        private var wantsPresentation = false

        init(isPresented: Binding<Bool>) {
            _isPresented = isPresented
        }

        func update(entry: SessionEntry) {
            let shouldRefresh = currentEntry?.id != entry.id
            currentEntry = entry
            if shouldRefresh {
                refreshContent()
            }
        }

        func anchorDidMoveToWindow() {
            guard anchorView?.window != nil else {
                popover?.performClose(nil)
                return
            }
            if wantsPresentation {
                present()
            }
        }

        func present() {
            wantsPresentation = true
            guard let anchorView, anchorView.window != nil else {
                return
            }
            anchorView.superview?.layoutSubtreeIfNeeded()
            let popover = popover ?? makePopover()
            if !popover.isShown {
                refreshContent()
                popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxX)
            }
        }

        func dismiss() {
            wantsPresentation = false
            popover?.performClose(nil)
        }

        func popoverDidClose(_ notification: Notification) {
            wantsPresentation = false
            popover = nil
            if isPresented {
                isPresented = false
            }
        }

        private func refreshContent() {
            guard let entry = currentEntry else { return }
            hostingController.rootView = AnyView(
                SessionTranscriptPreviewView(
                    entry: entry,
                    sizeModel: sizeModel,
                    onResize: { [weak self] proposedSize in
                        self?.resize(to: proposedSize)
                    }
                ) { [weak self] in
                    self?.closeFromContent()
                }
                .id(entry.id)
            )
            hostingController.view.invalidateIntrinsicContentSize()
            hostingController.view.layoutSubtreeIfNeeded()
            updatePopoverSize()
        }

        private func closeFromContent() {
            isPresented = false
            dismiss()
        }

        private func resize(to proposedSize: CGSize) {
            sizeModel.size = SessionTranscriptPreviewLayout.clamped(proposedSize)
            updatePopoverSize()
        }

        private func makePopover() -> NSPopover {
            let popover = NSPopover()
            popover.behavior = .transient
            popover.animates = true
            popover.contentViewController = hostingController
            popover.contentSize = NSSize(width: sizeModel.size.width, height: sizeModel.size.height)
            popover.delegate = self
            self.popover = popover
            return popover
        }

        private func updatePopoverSize() {
            popover?.contentSize = NSSize(width: sizeModel.size.width, height: sizeModel.size.height)
        }
    }
}

final class PopoverAnchorView: NSView {
    var onDidMoveToWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onDidMoveToWindow?()
    }
}

/// Invisible AppKit view that fires `onEscape` when Escape is pressed while
/// the popover content is key. Lives in the popover's view tree so it inherits
/// the popover's responder chain.
struct EscapeKeyCatcher: NSViewRepresentable {
    let onEscape: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = EscapeMonitorView()
        view.onEscape = onEscape
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? EscapeMonitorView)?.onEscape = onEscape
    }

    private final class EscapeMonitorView: NSView {
        var onEscape: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let win = self.window, win.isKeyWindow else { return event }
                if event.keyCode == 53 {
                    self.onEscape?()
                    return nil
                }
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

// MARK: - "Show more" popover with search

