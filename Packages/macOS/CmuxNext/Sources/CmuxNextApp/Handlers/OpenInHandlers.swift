import AppKit
import CmuxNextActions

/// Open-in-app and Reveal in Finder for the focused file. Until the file
/// preview surface lands, the focused file is a browser page showing a
/// `file://` URL (the catalog gates these on `filePreviewFocused`).
enum OpenInHandlers {
    static func bind(into registry: ActionRegistry, context: AppActionContext) {
        registry.bind("filePreviewOpenExternally", run: { try context.open(try focusedFile(context, $0)) })
        registry.bind("filePreviewRevealInFinder", run: { invocation in
            NSWorkspace.shared.activateFileViewerSelecting([try focusedFile(context, invocation)])
        })
        registry.bind("filePreviewOpenWith", run: { invocation in
            let file = try focusedFile(context, invocation)
            let name = invocation["app"]?.stringValue ?? ""
            guard let app = applicationURL(named: name) else { throw ActionFailure(message: MiscHandlerStrings.appNotFound(name)) }
            NSWorkspace.shared.open([file], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        })
    }

    static func focusedFile(_ context: AppActionContext, _ invocation: ActionInvocation) throws -> URL {
        guard case .browser(let entry) = context.scope(invocation).pane?.currentContent,
              let url = entry.tab.state.url, url.isFileURL else { throw ActionFailure(message: MiscHandlerStrings.noFile) }
        return url
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
