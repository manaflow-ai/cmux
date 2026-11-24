import Foundation

extension String {
    /// Whether this string's UTF-8 code units start with `prefix`'s (an equal string included).
    ///
    /// Two native strings (the composer's drafts, String+NativeCopy.swift) compare with one
    /// `memcmp` of their contiguous UTF-8: `utf8.starts(with:)` stepped a generic iterator code unit
    /// by code unit, which at a 10,000 character draft was a third of a key's work in the composer
    /// (`ComposeView.lines`, every key; HomeComposerKeyCostTests). A bridged string compares as
    /// before.
    func utf8HasPrefix(_ prefix: String) -> Bool {
        let fast: Bool?? = utf8.withContiguousStorageIfAvailable { whole in
            prefix.utf8.withContiguousStorageIfAvailable { start in
                guard start.count <= whole.count else { return false }
                guard let a = whole.baseAddress, let b = start.baseAddress, start.count > 0 else { return true }
                return memcmp(a, b, start.count) == 0
            }
        }
        if let known = fast.flatMap({ $0 }) { return known }
        return utf8.starts(with: prefix.utf8)
    }
}
