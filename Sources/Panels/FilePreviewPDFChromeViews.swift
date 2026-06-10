import AppKit
import AVKit
import Bonsplit
import Combine
import Foundation
import PDFKit
import Quartz
import SwiftUI
import UniformTypeIdentifiers


// MARK: - PDF Chrome
enum FilePreviewPDFSidebarMode {
    case thumbnails
    case tableOfContents
}

enum FilePreviewPDFDisplayMode {
    case continuousScroll
    case singlePage
    case twoPages
}

enum FilePreviewPDFChromeStyleVariant: String, CaseIterable, Identifiable {
    case systemControlGroup
    case liquidGlass
    case materialCapsule
    case borderedCapsule
    case thinOutline
    case plainToolbar

    static let defaultsKey = "filePreviewPDFChromeStyleVariant"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemControlGroup:
            String(localized: "filePreview.pdf.chromeStyle.systemControlGroup", defaultValue: "A: System Control Group")
        case .liquidGlass:
            String(localized: "filePreview.pdf.chromeStyle.liquidGlass", defaultValue: "B: Liquid Glass")
        case .materialCapsule:
            String(localized: "filePreview.pdf.chromeStyle.materialCapsule", defaultValue: "C: Material Pill")
        case .borderedCapsule:
            String(localized: "filePreview.pdf.chromeStyle.borderedCapsule", defaultValue: "D: Bordered Controls")
        case .thinOutline:
            String(localized: "filePreview.pdf.chromeStyle.thinOutline", defaultValue: "E: Thin Outline")
        case .plainToolbar:
            String(localized: "filePreview.pdf.chromeStyle.plainToolbar", defaultValue: "F: Plain Toolbar")
        }
    }

    static func current() -> FilePreviewPDFChromeStyleVariant {
        #if DEBUG
        if let rawValue = UserDefaults.standard.string(forKey: defaultsKey),
           let variant = FilePreviewPDFChromeStyleVariant(rawValue: rawValue) {
            return variant
        }
        #endif
        return .liquidGlass
    }

    func persist() {
        #if DEBUG
        UserDefaults.standard.set(rawValue, forKey: Self.defaultsKey)
        NotificationCenter.default.post(name: .filePreviewPDFChromeStyleDidChange, object: nil)
        #endif
    }
}

extension Notification.Name {
    static let filePreviewPDFChromeStyleDidChange = Notification.Name("filePreviewPDFChromeStyleDidChange")
}

final class FilePreviewPDFChromeHostView: NSView {
    var interactiveOverlayViews: [NSView] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        for overlayView in interactiveOverlayViews.reversed() where !overlayView.isHidden {
            let convertedPoint = convert(point, to: overlayView)
            if let hitView = interactiveHit(in: overlayView, at: convertedPoint) {
                return hitView
            }
        }
        return nil
    }

    private func interactiveHit(in view: NSView, at point: NSPoint) -> NSView? {
        guard !view.isHidden, view.bounds.contains(point) else { return nil }
        for subview in view.subviews.reversed() {
            let convertedPoint = view.convert(point, to: subview)
            if let hitView = interactiveHit(in: subview, at: convertedPoint) {
                return hitView
            }
        }
        return view is NSControl || view is FilePreviewPDFChromeHostingView ? view : nil
    }
}

final class FilePreviewPDFChromeHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

struct FilePreviewPDFSidebarChromeView: View {
    let isSidebarVisible: Bool
    let sidebarMode: FilePreviewPDFSidebarMode
    let displayMode: FilePreviewPDFDisplayMode
    let chromeStyleVariant: FilePreviewPDFChromeStyleVariant
    let toggleSidebar: () -> Void
    let selectThumbnails: () -> Void
    let selectTableOfContents: () -> Void
    let selectContinuousScroll: () -> Void
    let selectSinglePage: () -> Void
    let selectTwoPages: () -> Void

    var body: some View {
        if chromeStyleVariant == .systemControlGroup {
            ControlGroup {
                sidebarMenu
            } label: {
                Label(
                    String(localized: "filePreview.pdf.sidebarOptions", defaultValue: "Sidebar Options"),
                    systemImage: "sidebar.left"
                )
            }
            .controlSize(.regular)
            .accessibilityLabel(String(localized: "filePreview.pdf.sidebarOptions", defaultValue: "Sidebar Options"))
        } else if chromeStyleVariant == .liquidGlass {
            liquidGlassSidebarMenu
                .modifier(FilePreviewPDFChromeStyleModifier(variant: chromeStyleVariant))
                .accessibilityLabel(String(localized: "filePreview.pdf.sidebarOptions", defaultValue: "Sidebar Options"))
        } else {
            sidebarMenu
                .modifier(FilePreviewPDFChromeStyleModifier(variant: chromeStyleVariant))
                .accessibilityLabel(String(localized: "filePreview.pdf.sidebarOptions", defaultValue: "Sidebar Options"))
        }
    }

    private var sidebarMenu: some View {
        Menu {
            sidebarMenuItems
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 17, weight: .regular))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 58, height: 36)
            .contentShape(Capsule())
        }
    }

    private var liquidGlassSidebarMenu: some View {
        Menu {
            sidebarMenuItems
        } label: {
            FilePreviewChromeSidebarMenuLabel()
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var sidebarMenuItems: some View {
        Button(action: toggleSidebar) {
            Text(isSidebarVisible
                ? String(localized: "filePreview.pdf.hideSidebar", defaultValue: "Hide Sidebar")
                : String(localized: "filePreview.pdf.showSidebar", defaultValue: "Show Sidebar"))
        }
        checkedMenuButton(
            title: String(localized: "filePreview.pdf.thumbnails", defaultValue: "Thumbnails"),
            isSelected: sidebarMode == .thumbnails,
            action: selectThumbnails
        )
        checkedMenuButton(
            title: String(localized: "filePreview.pdf.tableOfContents", defaultValue: "Table of Contents"),
            isSelected: sidebarMode == .tableOfContents,
            action: selectTableOfContents
        )
        Divider()
        checkedMenuButton(
            title: String(localized: "filePreview.pdf.continuousScroll", defaultValue: "Continuous Scroll"),
            isSelected: displayMode == .continuousScroll,
            action: selectContinuousScroll
        )
        checkedMenuButton(
            title: String(localized: "filePreview.pdf.singlePage", defaultValue: "Single Page"),
            isSelected: displayMode == .singlePage,
            action: selectSinglePage
        )
        checkedMenuButton(
            title: String(localized: "filePreview.pdf.twoPages", defaultValue: "Two Pages"),
            isSelected: displayMode == .twoPages,
            action: selectTwoPages
        )
    }

    private func checkedMenuButton(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack {
                if isSelected {
                    Image(systemName: "checkmark")
                }
                Text(title)
            }
        }
    }
}

struct FilePreviewPDFZoomChromeView: View {
    let chromeStyleVariant: FilePreviewPDFChromeStyleVariant
    let fileURL: URL?
    let zoomOut: () -> Void
    let actualSize: () -> Void
    let zoomIn: () -> Void
    let zoomToFit: () -> Void
    let rotateLeft: () -> Void
    let rotateRight: () -> Void

    var body: some View {
        if chromeStyleVariant == .systemControlGroup {
            ControlGroup {
                zoomButtons(includeDividers: false)
                secondaryButtons(includeDividers: false)
                if let fileURL {
                    FileExternalOpenMenu(fileURL: fileURL, style: .chrome)
                }
            } label: {
                Label(
                    String(localized: "filePreview.pdf.zoomControls", defaultValue: "Zoom Controls"),
                    systemImage: "magnifyingglass"
                )
            }
            .controlSize(.regular)
        } else {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    zoomButtons(includeDividers: true)
                }
                .frame(height: chromeStyleVariant == .liquidGlass ? 40 : 36)
                .modifier(FilePreviewPDFChromeStyleModifier(variant: chromeStyleVariant))

                HStack(spacing: 0) {
                    secondaryButtons(includeDividers: true)
                }
                .frame(height: chromeStyleVariant == .liquidGlass ? 40 : 36)
                .modifier(FilePreviewPDFChromeStyleModifier(variant: chromeStyleVariant))

                if let fileURL {
                    HStack(spacing: 0) {
                        FileExternalOpenMenu(fileURL: fileURL, style: .chrome)
                    }
                    .frame(width: 40, height: 40)
                    .modifier(FilePreviewPDFStandaloneChromeStyleModifier(variant: chromeStyleVariant))
                }
            }
        }
    }

    @ViewBuilder
    private func zoomButtons(includeDividers: Bool) -> some View {
        chromeButton(
            systemName: "minus.magnifyingglass",
            label: String(localized: "filePreview.pdf.zoomOut", defaultValue: "Zoom Out"),
            action: zoomOut
        )
        if includeDividers {
            chromeDivider
        }
        chromeButton(
            systemName: "1.magnifyingglass",
            label: String(localized: "filePreview.pdf.actualSize", defaultValue: "Actual Size"),
            action: actualSize
        )
        if includeDividers {
            chromeDivider
        }
        chromeButton(
            systemName: "plus.magnifyingglass",
            label: String(localized: "filePreview.pdf.zoomIn", defaultValue: "Zoom In"),
            action: zoomIn
        )
    }

    @ViewBuilder
    private func secondaryButtons(includeDividers: Bool) -> some View {
        chromeButton(
            systemName: "arrow.up.left.and.arrow.down.right",
            label: String(localized: "filePreview.pdf.zoomToFit", defaultValue: "Zoom to Fit"),
            action: zoomToFit
        )
        if includeDividers {
            chromeDivider
        }
        chromeButton(
            systemName: "rotate.left",
            label: String(localized: "filePreview.pdf.rotateLeft", defaultValue: "Rotate Left"),
            action: rotateLeft
        )
        if includeDividers {
            chromeDivider
        }
        chromeButton(
            systemName: "rotate.right",
            label: String(localized: "filePreview.pdf.rotateRight", defaultValue: "Rotate Right"),
            action: rotateRight
        )
    }

    @ViewBuilder
    private func chromeButton(
        systemName: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        if chromeStyleVariant == .liquidGlass {
            FilePreviewChromeIconButton(systemName: systemName, label: label, action: action)
        } else {
            Button(action: action) {
                Image(systemName: systemName)
                    .font(.system(size: 16, weight: .regular))
                    .frame(width: 38, height: 36)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(label)
            .help(label)
        }
    }

    private var chromeDivider: some View {
        Divider()
            .frame(width: 1, height: 20)
            .overlay(
                chromeStyleVariant == .liquidGlass
                    ? Color.white.opacity(0.18)
                    : Color.clear
            )
    }
}

struct FilePreviewChromeIconButton: View {
    let systemName: String
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 42, height: 40)
        }
        .buttonStyle(FilePreviewChromeHoverButtonStyle(isHovered: isHovered))
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct FilePreviewChromeSidebarMenuLabel: View {
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sidebar.left")
            Image(systemName: "chevron.down")
                .font(.system(size: 11, weight: .semibold))
        }
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(isHovered ? Color.primary : Color.secondary)
        .frame(width: 68, height: 34)
        .background {
            Capsule()
                .fill(Color.white.opacity(isHovered ? 0.14 : 0))
        }
        .contentShape(Capsule())
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

private struct FilePreviewChromeHoverButtonStyle: ButtonStyle {
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed || isHovered ? Color.primary : Color.secondary)
            .background {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.24 : (isHovered ? 0.14 : 0)))
                    .frame(width: 32, height: 32)
            }
    }
}

struct FilePreviewPDFChromeStyleModifier: ViewModifier {
    let variant: FilePreviewPDFChromeStyleVariant

    @ViewBuilder
    func body(content: Content) -> some View {
        switch variant {
        case .systemControlGroup:
            content
                .buttonStyle(.automatic)
                .controlSize(.regular)
        case .liquidGlass:
            liquidGlassChrome(content: content)
        case .materialCapsule:
            materialChrome(content: content, material: .regularMaterial, strokeOpacity: 0.5)
        case .borderedCapsule:
            content
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.regular)
        case .thinOutline:
            materialChrome(content: content, material: .thinMaterial, strokeOpacity: 0.75)
        case .plainToolbar:
            content
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .foregroundStyle(Color.secondary)
        }
    }

    @ViewBuilder
    private func liquidGlassChrome(content: Content) -> some View {
        #if compiler(>=6.3)
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .glassEffect(.regular, in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.85)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 1)
        } else {
            content
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .background {
                    Capsule()
                        .fill(.regularMaterial)
                    Capsule()
                        .fill(Color.white.opacity(0.04))
                }
                .overlay {
                    Capsule()
                        .stroke(Color.white.opacity(0.28), lineWidth: 0.85)
                }
        }
        #else
        content
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .background {
                Capsule()
                    .fill(.regularMaterial)
                Capsule()
                    .fill(Color.white.opacity(0.04))
            }
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.28), lineWidth: 0.85)
            }
        #endif
    }

    private func materialChrome(
        content: Content,
        material: Material,
        strokeOpacity: Double
    ) -> some View {
        content
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .background(material, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color(nsColor: .separatorColor).opacity(strokeOpacity), lineWidth: 0.5)
            }
    }
}

struct FilePreviewPDFStandaloneChromeStyleModifier: ViewModifier {
    let variant: FilePreviewPDFChromeStyleVariant

    @ViewBuilder
    func body(content: Content) -> some View {
        switch variant {
        case .systemControlGroup:
            content
                .buttonStyle(.automatic)
                .controlSize(.regular)
        case .liquidGlass:
            liquidGlassChrome(content: content)
        case .materialCapsule:
            materialChrome(content: content, material: .regularMaterial, strokeOpacity: 0.5)
        case .borderedCapsule:
            materialChrome(content: content, material: .ultraThinMaterial, strokeOpacity: 0.55)
        case .thinOutline:
            materialChrome(content: content, material: .thinMaterial, strokeOpacity: 0.75)
        case .plainToolbar:
            content
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .foregroundStyle(Color.secondary)
        }
    }

    @ViewBuilder
    private func liquidGlassChrome(content: Content) -> some View {
        #if compiler(>=6.3)
        if #available(macOS 26.0, *) {
            content
                .buttonStyle(.borderless)
                .controlSize(.regular)
                .foregroundStyle(Color.secondary)
                .glassEffect(.regular, in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.white.opacity(0.24), lineWidth: 0.85)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 8, y: 1)
        } else {
            materialChrome(content: content, material: .regularMaterial, strokeOpacity: 0.28)
        }
        #else
        materialChrome(content: content, material: .regularMaterial, strokeOpacity: 0.28)
        #endif
    }

    private func materialChrome(
        content: Content,
        material: Material,
        strokeOpacity: Double
    ) -> some View {
        content
            .buttonStyle(.borderless)
            .controlSize(.regular)
            .foregroundStyle(Color.secondary)
            .background {
                Circle()
                    .fill(material)
                Circle()
                    .fill(Color.white.opacity(0.04))
            }
            .overlay {
                Circle()
                    .stroke(Color(nsColor: .separatorColor).opacity(strokeOpacity), lineWidth: 0.5)
            }
    }
}

