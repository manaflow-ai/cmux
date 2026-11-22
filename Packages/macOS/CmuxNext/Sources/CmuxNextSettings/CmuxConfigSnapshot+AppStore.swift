/// Whether the App Store shows. It stays hidden until it is ready (David Beyer, Nov 20, before the
/// Nov 23 launch: "don't show the app store until it's ready, it takes too much space"), so it is a
/// Labs preview: `labs.previewFeatures` on shows it, off (the default) hides its actions, its
/// sidebar item and its page. Its code and the stored sidebar layout stay either way.
extension CmuxConfigSnapshot {
    /// The App Store's actions, sidebar item and page show: Labs (`labs.previewFeatures`) is on.
    public var showsAppStore: Bool { previewFeatures }

    /// What a refused App Store action says while it is hidden: the Labs setting's title.
    public static var appStoreHiddenReason: String {
        SettingsSchema.descriptor(for: previewFeaturesPath)?.title ?? previewFeaturesPath.joined(separator: ".")
    }
}
