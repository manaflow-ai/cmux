public import AppKit

extension NSImage {
    /// Drawn for a symbol name this Mac's public SF Symbols catalog lacks (``systemSymbol(_:fallback:accessibilityDescription:)``).
    public nonisolated static let fallbackSymbolName = "questionmark.square.dashed"

    /// Whether `name` is in this Mac's public SF Symbols catalog: `NSImage(systemSymbolName:)` resolves it.
    /// - Parameter name: An SF Symbol name (`hammer.fill`).
    public nonisolated static func isSystemSymbol(_ name: String) -> Bool {
        !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }

    /// The public SF Symbol `name`, else `fallback`'s symbol, else nil.
    ///
    /// Use it for every symbol name that comes from data (a workspace or profile icon, a harness profile, a status from
    /// the CLI, a catalog): such a name can be misspelled, a newer system's, or private. A symbol only ever comes from the
    /// public catalog (`NSImage(systemSymbolName:)`), never from a system bundle such as `CoreGlyphsPrivate.bundle`: on
    /// macOS 27.3 a configured variant (`withSymbolConfiguration`) of a symbol the public catalog lacks aborts the app
    /// ("NSImage requested a variant from a symbol that wasn't found in the asset catalog").
    /// - Parameters:
    ///   - name: An SF Symbol name.
    ///   - fallback: The symbol drawn when `name` is not one; nil to answer nil instead.
    ///   - accessibilityDescription: The image's VoiceOver description.
    public nonisolated static func systemSymbol(_ name: String, fallback: String? = fallbackSymbolName,
                                                accessibilityDescription: String? = nil) -> NSImage? {
        if !name.isEmpty, let image = NSImage(systemSymbolName: name, accessibilityDescription: accessibilityDescription) {
            return image
        }
        guard let fallback, fallback != name, !fallback.isEmpty else { return nil }
        return NSImage(systemSymbolName: fallback, accessibilityDescription: accessibilityDescription)
    }
}
