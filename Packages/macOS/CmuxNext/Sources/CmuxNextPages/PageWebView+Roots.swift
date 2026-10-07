import CmuxNextSettings
public import Foundation

/// Where a page's files come from, and the script that sets its document attributes.
extension PageWebView {
    /// The root a page is served from without an explicit one: the DEBUG override, else this
    /// module's bundled directory, else the root registered for its id.
    nonisolated static func servedRoot(for descriptor: PageDescriptor) -> URL? {
        debugRoot(for: descriptor) ?? PageSchemeHandler.bundledRoot(for: descriptor) ?? PageID.bundledRoot(for: descriptor.id)
    }

    /// The script that sets `data-<name>` attributes on `<html>`; nil for none. Names keep only
    /// lowercase letters, digits and dashes; values are JSON string literals.
    nonisolated static func attributesScript(_ attributes: [String: String]) -> String? {
        let safe = attributes.filter { name, _ in !name.isEmpty && name.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" } }
        guard !safe.isEmpty else { return nil }
        let lines = safe.keys.sorted().map { name in
            "document.documentElement.setAttribute(\(JSONValue.string("data-" + name).compactText), \(JSONValue.string(safe[name] ?? "").compactText));"
        }
        return lines.joined(separator: "\n")
    }

    /// The DEBUG root override of a page (`CMUX_NEXT_PAGE_ROOT_cmux_history=/path`), else nil.
    nonisolated static func debugRoot(for descriptor: PageDescriptor) -> URL? {
        #if DEBUG
        let name = "CMUX_NEXT_PAGE_ROOT_" + descriptor.id.replacingOccurrences(of: ".", with: "_")
        return ProcessInfo.processInfo.environment[name].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        return nil
        #endif
    }

    /// Whether `descriptor` may be served from `root`: any root for an app page; for a first-party
    /// page only its bundled root or its DEBUG override.
    nonisolated static func mayServe(_ descriptor: PageDescriptor, from root: URL) -> Bool {
        guard PageID.isReserved(descriptor.id) else { return true }
        let wanted = root.standardizedFileURL.resolvingSymlinksInPath().path
        let allowed = [PageSchemeHandler.bundledRoot(for: descriptor), PageID.bundledRoot(for: descriptor.id),
                       debugRoot(for: descriptor)].compactMap { $0 }
        return allowed.contains { $0.standardizedFileURL.resolvingSymlinksInPath().path == wanted }
    }
}
