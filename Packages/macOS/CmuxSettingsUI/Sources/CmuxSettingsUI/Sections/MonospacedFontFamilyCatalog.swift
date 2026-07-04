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
            let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
            return CTFontGetSymbolicTraits(font).contains(.traitMonoSpace)
        }
    }
}
