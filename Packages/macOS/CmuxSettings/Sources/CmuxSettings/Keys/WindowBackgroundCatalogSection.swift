import CmuxFoundation

/// Settings under the dotted-id prefix `windowBackground.*`.
///
/// One image painted behind the titlebar, sidebar and every terminal pane of
/// a cmux window. An empty ``image`` path turns the feature off, which is the
/// default. The `UserDefaults` keys come from
/// ``WindowBackgroundImageSettings`` so the window chrome reads the same
/// storage.
public struct WindowBackgroundCatalogSection: SettingCatalogSection {
    /// The image file: an absolute path or one starting with `~/`. Empty means
    /// no background image.
    public let image = DefaultsKey<String>(
        id: "windowBackground.image",
        defaultValue: "",
        userDefaultsKey: WindowBackgroundImageSettings.pathDefaultsKey
    )

    /// How visible the image is over the terminal background color, from 0
    /// to 1. Lower values keep text easier to read.
    public let imageOpacity = DefaultsKey<Double>(
        id: "windowBackground.imageOpacity",
        defaultValue: WindowBackgroundImageSettings.defaultOpacity,
        userDefaultsKey: WindowBackgroundImageSettings.opacityDefaultsKey
    )

    /// How the image is scaled to the window.
    public let imageFit = DefaultsKey<WindowBackgroundImageFit>(
        id: "windowBackground.imageFit",
        defaultValue: WindowBackgroundImageSettings.defaultFit,
        userDefaultsKey: WindowBackgroundImageSettings.fitDefaultsKey
    )

    /// Creates the window background settings section with its default keys.
    public init() {}
}
