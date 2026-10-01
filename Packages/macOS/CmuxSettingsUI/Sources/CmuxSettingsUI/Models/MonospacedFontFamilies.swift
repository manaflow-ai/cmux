import CoreText
import Foundation

/// Lists the installed font families with a fixed-pitch face, the choices the
/// terminal font picker offers.
struct MonospacedFontFamilies: Sendable {
    /// Sorted family names. Hidden system families (named with a leading dot)
    /// are left out. CoreText is thread-safe, so call this off the main actor.
    func load() -> [String] {
        let collection = CTFontCollectionCreateFromAvailableFonts(nil)
        guard let descriptors = CTFontCollectionCreateMatchingFontDescriptors(collection) as? [CTFontDescriptor] else {
            return []
        }
        var families = Set<String>()
        for descriptor in descriptors {
            guard let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? [String: Any],
                  let symbolic = traits[kCTFontSymbolicTrait as String] as? NSNumber,
                  CTFontSymbolicTraits(rawValue: symbolic.uint32Value).contains(.traitMonoSpace),
                  let family = CTFontDescriptorCopyAttribute(descriptor, kCTFontFamilyNameAttribute) as? String,
                  !family.hasPrefix(".") else {
                continue
            }
            families.insert(family)
        }
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
