import CoreText
import Foundation

struct MonospacedFontFamilyCatalog {
    func families() -> [String] {
        let families = (CTFontManagerCopyAvailableFontFamilyNames() as NSArray)
            .compactMap { $0 as? String }
        return families
            .filter(isMonospacedFamily)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func isMonospacedFamily(_ family: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes([
            kCTFontFamilyNameAttribute: family
        ] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor] ?? []
        return matches.contains { descriptor in
            guard
                let traits = CTFontDescriptorCopyAttribute(descriptor, kCTFontTraitsAttribute) as? NSDictionary,
                let symbolicTraits = traits[kCTFontSymbolicTrait] as? NSNumber
            else {
                return false
            }
            return CTFontSymbolicTraits(rawValue: symbolicTraits.uint32Value).contains(.traitMonoSpace)
        }
    }
}
