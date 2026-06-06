import AppKit
import SwiftUI

/// Renders a session agent icon from the asset catalog, with a stable symbol fallback.
struct AgentIconImage: View, Equatable {
    let agent: SessionAgent
    let size: CGFloat

    var body: some View {
        if let assetName = agent.assetName {
            if let image = SessionIndexIconResolver.assetImage(named: assetName) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            } else {
                Image(assetName)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size, height: size)
            }
        } else {
            SessionIndexTemplateSymbolImage(
                systemName: agent.systemImageName ?? "person.crop.circle",
                size: size,
                pointSize: max(size - 2, 10),
                fallback: nil
            )
        }
    }
}

/// Shared session-index section icon renderer used by sidebar rows and previews.
struct SectionIconImage: View, Equatable {
    let icon: SectionIcon
    let size: CGFloat

    var body: some View {
        switch icon {
        case .agent(let agent):
            AgentIconImage(agent: agent, size: size)
        case .folder:
            SessionIndexTemplateSymbolImage(
                systemName: "folder",
                size: size,
                pointSize: max(size - 2, 10),
                fallback: .folder
            )
        }
    }
}

/// Renders SF Symbols through AppKit so lazy list rows get a concrete image layer.
private struct SessionIndexTemplateSymbolImage: View, Equatable {
    let systemName: String
    let size: CGFloat
    let pointSize: CGFloat
    let fallback: SessionIndexIconResolver.Fallback?

    var body: some View {
        if let image = SessionIndexIconResolver.templateSymbolImage(
            named: systemName,
            fallback: fallback
        ) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.secondary)
                .frame(width: size, height: size)
        } else {
            Image(systemName: systemName)
                .font(.system(size: pointSize, weight: .regular))
                .foregroundColor(.secondary)
                .frame(width: size, height: size)
        }
    }
}

@MainActor
private enum SessionIndexIconResolver {
    enum Fallback: Equatable {
        case folder
    }

    /// Returns a catalog image only when AppKit reports it as renderable.
    static func assetImage(named name: String) -> NSImage? {
        guard let image = NSImage(named: name), image.isRenderableForSessionIndex else {
            return nil
        }
        return image
    }

    /// Resolves a template symbol and falls back to Finder's folder icon when needed.
    static func templateSymbolImage(named name: String, fallback: Fallback?) -> NSImage? {
        if let image = NSImage(systemSymbolName: name, accessibilityDescription: nil),
           image.isRenderableForSessionIndex {
            return image.sessionIndexTemplateCopy()
        }

        switch fallback {
        case .folder:
            let image = NSWorkspace.shared.icon(for: .folder)
            guard image.isRenderableForSessionIndex else { return nil }
            return image.sessionIndexTemplateCopy()
        case nil:
            return nil
        }
    }
}

@MainActor
private extension NSImage {
    /// Filters out empty AppKit images before handing them to SwiftUI.
    var isRenderableForSessionIndex: Bool {
        isValid && size.width > 0 && size.height > 0
    }

    /// Returns a template image without mutating shared cached AppKit images.
    func sessionIndexTemplateCopy() -> NSImage {
        let image: NSImage
        if let copiedImage = copy() as? NSImage, copiedImage !== self {
            image = copiedImage
        } else {
            image = tiffRepresentation.flatMap(NSImage.init(data:))
                ?? sessionIndexRasterizedCopy()
        }
        image.isTemplate = true
        return image
    }

    private func sessionIndexRasterizedCopy() -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        draw(
            in: NSRect(origin: .zero, size: size),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        image.unlockFocus()
        return image
    }
}
