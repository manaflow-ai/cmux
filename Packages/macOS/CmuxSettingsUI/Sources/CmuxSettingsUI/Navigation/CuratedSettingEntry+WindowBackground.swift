import Foundation

extension Array where Element == CuratedSettingEntry {
    /// Search entries for the Themes window background image rows
    /// (`windowBackground.*`), appended to ``cmuxDefault(catalog:)``.
    static var windowBackgroundEntries: [CuratedSettingEntry] {
        [
            .init(
                section: .themes,
                id: "window-background-image",
                title: WindowBackgroundSettingsCard.imageTitle,
                paths: ["windowBackground.image"],
                synonyms: "Background Image windowBackground.image wallpaper picture photo backdrop window background image transparent warp"
            ),
            .init(
                section: .themes,
                id: "window-background-image-opacity",
                title: WindowBackgroundSettingsCard.opacityTitle,
                paths: ["windowBackground.imageOpacity"],
                synonyms: "Background Image Opacity windowBackground.imageOpacity wallpaper dim dimming readability contrast transparency"
            ),
            .init(
                section: .themes,
                id: "window-background-image-fit",
                title: WindowBackgroundSettingsCard.fitTitle,
                paths: ["windowBackground.imageFit"],
                synonyms: "Background Image Fit windowBackground.imageFit wallpaper cover contain stretch fill scale"
            ),
        ]
    }
}
