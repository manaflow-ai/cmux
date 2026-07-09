import Foundation

extension String {
    /// This text with its trailing word removed, used by the omnibar's
    /// delete-word-backward path: enumerates word boundaries in reverse and
    /// returns the substring up to the start of the last word.
    public var omnibarPrefixAfterDeletingTrailingWord: String {
        let nsText = self as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var deletionStart = nsText.length
        nsText.enumerateSubstrings(in: fullRange, options: [.byWords, .reverse]) { _, range, _, stop in
            deletionStart = range.location
            stop.pointee = true
        }
        return nsText.substring(to: deletionStart)
    }
}
