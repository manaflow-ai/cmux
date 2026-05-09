import AppKit
import SwiftUI

private enum PDFPreviewChromeDebugAction {
    case zoomOut
    case actualSize
    case zoomIn
    case zoomToFit
    case rotateLeft
    case rotateRight

    var title: String {
        switch self {
        case .zoomOut:
            String(localized: "filePreview.pdf.zoomOut", defaultValue: "Zoom Out")
        case .actualSize:
            String(localized: "filePreview.pdf.actualSize", defaultValue: "Actual Size")
        case .zoomIn:
            String(localized: "filePreview.pdf.zoomIn", defaultValue: "Zoom In")
        case .zoomToFit:
            String(localized: "filePreview.pdf.zoomToFit", defaultValue: "Zoom to Fit")
        case .rotateLeft:
            String(localized: "filePreview.pdf.rotateLeft", defaultValue: "Rotate Left")
        case .rotateRight:
            String(localized: "filePreview.pdf.rotateRight", defaultValue: "Rotate Right")
        }
    }

    var systemName: String {
        switch self {
        case .zoomOut:
            "minus.magnifyingglass"
        case .actualSize:
            "1.magnifyingglass"
        case .zoomIn:
            "plus.magnifyingglass"
        case .zoomToFit:
            "arrow.up.left.and.arrow.down.right"
        case .rotateLeft:
            "rotate.left"
        case .rotateRight:
            "rotate.right"
        }
    }
}

private final class PDFPreviewChromeDebugModel: ObservableObject {
    @Published var lastActionTitle = ""
    @Published var actionCount = 0

    func record(_ action: PDFPreviewChromeDebugAction) {
        lastActionTitle = action.title
        actionCount += 1
    }
}

private struct PDFPreviewChromeDebugView: View {
    @ObservedObject var model: PDFPreviewChromeDebugModel

    @AppStorage(FilePreviewPDFChromeStyleVariant.defaultsKey)
    private var chromeStyleRawValue = FilePreviewPDFChromeStyleVariant.liquidGlass.rawValue

    private var currentVariant: FilePreviewPDFChromeStyleVariant {
        FilePreviewPDFChromeStyleVariant(rawValue: chromeStyleRawValue) ?? .liquidGlass
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(String(localized: "debug.pdfPreviewChrome.heading", defaultValue: "PDF Preview Chrome"))
                    .font(.headline)

                Text(
                    String(
                        localized: "debug.pdfPreviewChrome.description",
                        defaultValue: "Choose the floating control style used by PDF previews."
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                GroupBox(String(localized: "debug.pdfPreviewChrome.toolbarReference", defaultValue: "Native Window Toolbar")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(
                            String(
                                localized: "debug.pdfPreviewChrome.toolbarReferenceDescription",
                                defaultValue: "Use the buttons in this debug window's titlebar toolbar to test real NSToolbar hover and press feedback."
                            )
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                        actionStatus
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 2)
                }

                ForEach(FilePreviewPDFChromeStyleVariant.allCases) { variant in
                    variantRow(variant)
                }

                Divider()

                HStack(spacing: 10) {
                    Text(
                        String(
                            format: String(
                                localized: "debug.pdfPreviewChrome.currentFormat",
                                defaultValue: "Current: %@"
                            ),
                            currentVariant.title
                        )
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                    Spacer()

                    Button(String(localized: "debug.pdfPreviewChrome.copyConfig", defaultValue: "Copy Config")) {
                        copyConfig()
                    }

                    Button(String(localized: "debug.pdfPreviewChrome.resetToDefault", defaultValue: "Reset to Default")) {
                        apply(.liquidGlass)
                    }
                }
            }
            .padding(16)
        }
        .frame(width: 500, height: 620)
    }

    @ViewBuilder
    private var actionStatus: some View {
        if model.actionCount == 0 {
            Text(String(localized: "debug.pdfPreviewChrome.noActions", defaultValue: "No sample actions yet."))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        } else {
            Text(
                String(
                    format: String(
                        localized: "debug.pdfPreviewChrome.lastActionFormat",
                        defaultValue: "Last action: %@ (%d)"
                    ),
                    model.lastActionTitle,
                    model.actionCount
                )
            )
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.secondary)
        }
    }

    private func variantRow(_ variant: FilePreviewPDFChromeStyleVariant) -> some View {
        let isSelected = variant == currentVariant

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 16)

                Text(variant.title)
                    .font(.system(size: 13, weight: .medium))

                Spacer()

                Button(
                    isSelected
                        ? String(localized: "debug.pdfPreviewChrome.selected", defaultValue: "Selected")
                        : String(localized: "debug.pdfPreviewChrome.use", defaultValue: "Use")
                ) {
                    apply(variant)
                }
                .disabled(isSelected)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Text(String(localized: "debug.pdfPreviewChrome.sampleLabel", defaultValue: "Sample"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 48, alignment: .leading)

                PDFPreviewChromeDebugSample(variant: variant, model: model)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private func apply(_ variant: FilePreviewPDFChromeStyleVariant) {
        chromeStyleRawValue = variant.rawValue
        variant.persist()
    }

    private func copyConfig() {
        let payload = "\(FilePreviewPDFChromeStyleVariant.defaultsKey)=\(currentVariant.rawValue)"
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)
    }
}

private struct PDFPreviewChromeDebugSample: View {
    let variant: FilePreviewPDFChromeStyleVariant
    @ObservedObject var model: PDFPreviewChromeDebugModel

    var body: some View {
        FilePreviewPDFZoomChromeView(
            chromeStyleVariant: variant,
            zoomOut: { model.record(.zoomOut) },
            actualSize: { model.record(.actualSize) },
            zoomIn: { model.record(.zoomIn) },
            zoomToFit: { model.record(.zoomToFit) },
            rotateLeft: { model.record(.rotateLeft) },
            rotateRight: { model.record(.rotateRight) }
        )
    }
}

final class PDFPreviewChromeDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = PDFPreviewChromeDebugWindowController()
    private static let zoomOutItemID = NSToolbarItem.Identifier("cmux.pdfPreviewChromeDebug.zoomOut")
    private static let actualSizeItemID = NSToolbarItem.Identifier("cmux.pdfPreviewChromeDebug.actualSize")
    private static let zoomInItemID = NSToolbarItem.Identifier("cmux.pdfPreviewChromeDebug.zoomIn")
    private static let zoomToFitItemID = NSToolbarItem.Identifier("cmux.pdfPreviewChromeDebug.zoomToFit")
    private static let rotateLeftItemID = NSToolbarItem.Identifier("cmux.pdfPreviewChromeDebug.rotateLeft")
    private static let rotateRightItemID = NSToolbarItem.Identifier("cmux.pdfPreviewChromeDebug.rotateRight")

    private let model = PDFPreviewChromeDebugModel()

    private init() {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 660),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.pdfPreviewChrome.windowTitle", defaultValue: "PDF Preview Chrome")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.pdfPreviewChromeDebug")
        window.center()
        window.contentView = NSHostingView(rootView: PDFPreviewChromeDebugView(model: model))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        super.init(window: window)
        window.delegate = self
        installToolbar(on: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    private func installToolbar(on window: NSWindow) {
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("cmux.pdfPreviewChromeDebug.toolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unifiedCompact
    }

    @objc private func toolbarZoomOut(_ sender: Any?) {
        model.record(.zoomOut)
    }

    @objc private func toolbarActualSize(_ sender: Any?) {
        model.record(.actualSize)
    }

    @objc private func toolbarZoomIn(_ sender: Any?) {
        model.record(.zoomIn)
    }

    @objc private func toolbarZoomToFit(_ sender: Any?) {
        model.record(.zoomToFit)
    }

    @objc private func toolbarRotateLeft(_ sender: Any?) {
        model.record(.rotateLeft)
    }

    @objc private func toolbarRotateRight(_ sender: Any?) {
        model.record(.rotateRight)
    }

    private func makeToolbarItem(
        identifier: NSToolbarItem.Identifier,
        action: PDFPreviewChromeDebugAction,
        selector: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = action.title
        item.paletteLabel = action.title
        item.toolTip = action.title
        item.image = NSImage(systemSymbolName: action.systemName, accessibilityDescription: action.title)
        item.target = self
        item.action = selector
        item.isBordered = true
        return item
    }
}

extension PDFPreviewChromeDebugWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.zoomOutItemID,
            Self.actualSizeItemID,
            Self.zoomInItemID,
            Self.zoomToFitItemID,
            Self.rotateLeftItemID,
            Self.rotateRightItemID,
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.zoomOutItemID,
            Self.actualSizeItemID,
            Self.zoomInItemID,
            Self.zoomToFitItemID,
            Self.rotateLeftItemID,
            Self.rotateRightItemID,
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.zoomOutItemID:
            makeToolbarItem(identifier: itemIdentifier, action: .zoomOut, selector: #selector(toolbarZoomOut(_:)))
        case Self.actualSizeItemID:
            makeToolbarItem(identifier: itemIdentifier, action: .actualSize, selector: #selector(toolbarActualSize(_:)))
        case Self.zoomInItemID:
            makeToolbarItem(identifier: itemIdentifier, action: .zoomIn, selector: #selector(toolbarZoomIn(_:)))
        case Self.zoomToFitItemID:
            makeToolbarItem(identifier: itemIdentifier, action: .zoomToFit, selector: #selector(toolbarZoomToFit(_:)))
        case Self.rotateLeftItemID:
            makeToolbarItem(identifier: itemIdentifier, action: .rotateLeft, selector: #selector(toolbarRotateLeft(_:)))
        case Self.rotateRightItemID:
            makeToolbarItem(identifier: itemIdentifier, action: .rotateRight, selector: #selector(toolbarRotateRight(_:)))
        default:
            nil
        }
    }
}
