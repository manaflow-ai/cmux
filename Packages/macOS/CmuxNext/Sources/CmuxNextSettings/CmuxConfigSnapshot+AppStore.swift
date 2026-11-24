/// Whether the App Store shows. It stays hidden until it is ready (David Beyer, Nov 20: "don't show
/// the app store until it's ready, it takes too much space"; Lawrence, Nov 23: "get rid of app store
/// from default for now"), behind its own switch, `labs.appStore`, off by default. It is apart from
/// Show Preview Features (`labs.previewFeatures`), which the music player, Click by Hint and Stats
/// ask people to turn on. Its code and the stored sidebar layout stay either way.
extension CmuxConfigSnapshot {
    /// The App Store's actions, sidebar item and page show: `labs.appStore` is on.
    public var showsAppStore: Bool { appStore }

    /// What a refused App Store action says while it is hidden: the `labs.appStore` setting's title.
    public static var appStoreHiddenReason: String {
        SettingsSchema.descriptor(for: appStorePath)?.title ?? appStorePath.joined(separator: ".")
    }
}
