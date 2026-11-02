import Foundation

/// NativePopupSlider on the native popup wire.
public struct NativePopupSlider: Codable, Equatable, Sendable {
    public var `stops`: [NativePopupSliderStop]
    public var `selectedValue`: String?
    public var `defaultValue`: String?
    public var `recommendedValue`: String?
    public var `recommendedLabel`: String?
    public var `minimumLabel`: String?
    public var `maximumLabel`: String?
    public var `accessibilityLabel`: String?
    public var `style`: NativePopupSliderStyle?

    public init(stops: [NativePopupSliderStop], selectedValue: String? = nil, defaultValue: String? = nil, recommendedValue: String? = nil, recommendedLabel: String? = nil, minimumLabel: String? = nil, maximumLabel: String? = nil, accessibilityLabel: String? = nil, style: NativePopupSliderStyle? = nil) {
        self.stops = stops
        self.selectedValue = selectedValue
        self.defaultValue = defaultValue
        self.recommendedValue = recommendedValue
        self.recommendedLabel = recommendedLabel
        self.minimumLabel = minimumLabel
        self.maximumLabel = maximumLabel
        self.accessibilityLabel = accessibilityLabel
        self.style = style
    }
}
