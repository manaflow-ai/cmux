import AppKit
import AVKit
import Bonsplit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers


// MARK: - Panel View & Content Representables
struct FilePreviewPanelView: View {
    var panel: FilePreviewPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let appearance: PanelAppearance
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity = 0.0
    @State private var focusFlashAnimationGeneration = 0
    @AppStorage(FilePreviewWordWrapSettings.key) private var fileEditorWordWrap = FilePreviewWordWrapSettings.defaultEnabled

    private var themeForegroundColor: NSColor {
        appearance.foregroundColor
    }

    private var contentBackgroundColor: NSColor {
        appearance.contentBackgroundColor
    }

    var body: some View {
        VStack(spacing: 0) {
            if panel.previewMode != .pdf {
                header
                Divider()
            }
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: contentBackgroundColor))
        .overlay {
            WorkspaceAttentionFlashRingView(opacity: focusFlashOpacity)
        }
        .overlay {
            if isVisibleInUI {
                FilePreviewPointerObserver(onPointerDown: onRequestPanelFocus)
            }
        }
        .onChange(of: panel.focusFlashToken) {
            triggerFocusFlashAnimation()
        }
    }

    private var header: some View {
        PanelFilePathHeader(
            iconSystemName: panel.displayIcon ?? "doc.viewfinder",
            filePath: panel.filePath,
            foregroundColor: themeForegroundColor
        ) {
            if panel.previewMode == .text {
                PanelHeaderIconButton(
                    systemName: "arrow.counterclockwise",
                    label: String(localized: "filePreview.revert", defaultValue: "Revert"),
                    isDisabled: !panel.isDirty,
                    action: { panel.loadTextContent() }
                )

                PanelHeaderIconButton(
                    systemName: "square.and.arrow.down",
                    label: String(localized: "filePreview.save", defaultValue: "Save"),
                    isDisabled: !panel.isDirty || panel.isSaving,
                    action: { panel.saveTextContent() }
                )
            }

            FileExternalOpenMenu(fileURL: panel.fileURL, isDisabled: panel.isFileUnavailable)
        }
    }

    @ViewBuilder
    private var content: some View {
        if panel.isFileUnavailable {
            fileUnavailableView
        } else {
            switch panel.previewMode {
            case .text:
                FilePreviewTextEditor(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    themeBackgroundColor: contentBackgroundColor,
                    themeForegroundColor: themeForegroundColor,
                    drawsBackground: appearance.drawsContentBackground,
                    wordWrap: fileEditorWordWrap
                )
            case .pdf:
                FilePreviewPDFView(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    backgroundColor: contentBackgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                )
            case .image:
                FilePreviewImageView(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    backgroundColor: contentBackgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                )
            case .media:
                FilePreviewMediaView(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    backgroundColor: contentBackgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                )
            case .quickLook:
                QuickLookPreviewView(
                    panel: panel,
                    isVisibleInUI: isVisibleInUI,
                    backgroundColor: contentBackgroundColor,
                    drawsBackground: appearance.drawsContentBackground
                )
            }
        }
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(String(localized: "filePreview.fileUnavailable.title", defaultValue: "File unavailable"))
                .font(.headline)
            Text(panel.filePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "filePreview.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

private struct FilePreviewPDFView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> FilePreviewPDFContainerView {
        panel.nativeViewSessions.pdf.view(
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ nsView: FilePreviewPDFContainerView, context: Context) {
        panel.nativeViewSessions.pdf.update(
            nsView,
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}

private struct FilePreviewImageView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> FilePreviewImageContainerView {
        panel.nativeViewSessions.image.view(
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ nsView: FilePreviewImageContainerView, context: Context) {
        panel.nativeViewSessions.image.update(
            nsView,
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}

private struct FilePreviewMediaView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    func makeNSView(context: Context) -> AVPlayerView {
        panel.nativeViewSessions.media.view(
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        panel.nativeViewSessions.media.update(
            nsView,
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }
}

private struct QuickLookPreviewView: NSViewRepresentable {
    let panel: FilePreviewPanel
    let isVisibleInUI: Bool
    let backgroundColor: NSColor
    let drawsBackground: Bool

    final class Coordinator {
        var quickLook: FilePreviewQuickLookSession?

        init(panel: FilePreviewPanel) {
            quickLook = panel.nativeViewSessions.quickLook
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel)
    }

    func makeNSView(context: Context) -> NSView {
        let quickLook = panel.nativeViewSessions.quickLook
        context.coordinator.quickLook = quickLook
        return quickLook.view(
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let quickLook = panel.nativeViewSessions.quickLook
        context.coordinator.quickLook = quickLook
        quickLook.update(
            nsView,
            panel: panel,
            isVisibleInUI: isVisibleInUI,
            backgroundColor: backgroundColor,
            drawsBackground: drawsBackground
        )
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.quickLook?.dismantle(nsView)
        coordinator.quickLook = nil
    }
}

private struct FilePreviewPointerObserver: NSViewRepresentable {
    let onPointerDown: () -> Void

    func makeNSView(context: Context) -> FilePreviewPointerObserverView {
        let view = FilePreviewPointerObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    func updateNSView(_ nsView: FilePreviewPointerObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}

private final class FilePreviewPointerObserverView: NSView {
    var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            guard let self,
                  event.window === self.window,
                  !self.isHiddenOrHasHiddenAncestor else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            if self.bounds.contains(point) {
                DispatchQueue.main.async { [weak self] in
                    self?.onPointerDown?()
                }
            }
            return event
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
