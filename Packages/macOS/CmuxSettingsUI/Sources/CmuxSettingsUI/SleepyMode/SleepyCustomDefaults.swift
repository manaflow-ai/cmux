import Foundation

/// Default custom colors (matched to the cmux theme so "Custom" starts
/// familiar). A `struct` rather than a caseless namespace `enum` per the cmux
/// package-design policy; values are "RRGGBB" hex.
public struct SleepyCustomDefaults {
    /// Default custom face color.
    public static let face = "E0EDFF"
    /// Default custom nightcap color.
    public static let cap = "5CD6FF"
    /// Default custom blush color.
    public static let blush = "FF99B5"
    /// Default custom eye/ink color.
    public static let ink = "333D6B"
    /// Default custom logo color.
    public static let logo = "6BDEFF"
    /// Default custom background color.
    public static let background = "060812"

    private init() {}
}
