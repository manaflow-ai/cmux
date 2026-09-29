import AppKit
import CmuxNextActions

/// Open-in-app and Reveal in Finder for the focused file. Until the file
/// preview surface lands, the focused file is a browser page showing a
/// `file://` URL (the catalog gates these on `filePreviewFocused`).
enum OpenInHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("filePreviewOpenExternally", invoke: { invocation in
            guard let file = focusedFile(context, invocation) else { return }
            NSWorkspace.shared.open(file)
        })
        registry.bind("filePreviewRevealInFinder", invoke: { invocation in
            guard let file = focusedFile(context, invocation) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([file])
        })
        registry.bind("filePreviewOpenWith", invoke: { invocation in
            guard let file = focusedFile(context, invocation) else { return }
            let name = invocation["app"]?.stringValue ?? ""
            guard let app = applicationURL(named: name) else { return context.fail(HandlerStrings.appNotFound(name)) }
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        })
    }

    static func focusedFile(_ context: AppActionContext, _ invocation: ActionInvocation) -> URL? {
        if case .browser(let entry) = context.scope(invocation).pane?.currentContent,
           let url = entry.tab.state.url, url.isFileURL {
            return url
        }
        context.fail(HandlerStrings.noFile)
        return nil
    }

    /// Resolves a bundle identifier, an app path, or an app name
    /// ("Visual Studio Code") in the standard application folders.
    static func applicationURL(named name: String) -> URL? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: trimmed) { return url }
        if trimmed.hasPrefix("/"), FileManager.default.fileExists(atPath: trimmed) { return URL(fileURLWithPath: trimmed) }
        let bundleName = trimmed.hasSuffix(".app") ? trimmed : trimmed + ".app"
        let folders = FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask, .systemDomainMask])
            + [URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/Applications/Utilities")]
        return folders.map { $0.appendingPathComponent(bundleName) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
