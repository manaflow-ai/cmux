public import Foundation

extension String {
    /// The canonical identity used to decide whether two file-backed surfaces
    /// (markdown, file preview) show the same file.
    ///
    /// Paths are compared after symlink resolution so `./README.md` and a
    /// symlink pointing at the same file resolve to one viewer, matching the
    /// legacy `(filePath as NSString).resolvingSymlinksInPath` comparison the
    /// `openOrFocus…` lookups performed on both the request and each candidate.
    public var surfaceFilePathIdentity: String {
        (self as NSString).resolvingSymlinksInPath
    }
}
