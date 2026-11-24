extension BrowserTab {
    /// Tells `changed` at each change of the page's picture version (``BrowserTabState/pictureVersion``: a navigation,
    /// a title, a load), after the turn that changed it, until the returned stop runs: a hover card watching the
    /// page's live picture.
    public func watchPictureVersion(_ changed: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        var seen: Int?
        let loop = ObservationLoop { [weak self] in
            guard let version = self?.state.pictureVersion else { return }
            defer { seen = version }
            if seen != nil, seen != version { changed() }
        }
        return { loop.cancel() }
    }
}
