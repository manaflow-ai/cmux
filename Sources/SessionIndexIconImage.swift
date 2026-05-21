import AppKit
import SwiftUI

/// Renders a session agent icon from the asset catalog, with a stable symbol fallback.
struct AgentIconImage: View, Equatable {
    let agent: SessionAgent
    let size: CGFloat

    var body: some View {
        if let assetName = agent.assetName,
           let image = SessionIndexIconResolver.assetImage(named: assetName) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
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

private extension NSImage {
    /// Filters out empty AppKit images before handing them to SwiftUI.
    var isRenderableForSessionIndex: Bool {
        isValid && size.width > 0 && size.height > 0
    }

    /// Copies before template mutation so shared cached AppKit images stay untouched.
    func sessionIndexTemplateCopy() -> NSImage {
        guard let image = copy() as? NSImage else {
            return self
        }
        image.isTemplate = true
        return image
    }
}
