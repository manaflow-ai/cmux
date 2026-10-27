#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextCompat
public import Foundation

extension OracleAccessibilityFacet.StringTable {
    /// The string tables of `main` and of the package resource bundles in `resources` (where the app keeps them),
    /// each in the localization the bundle shows. It reads the disk: never on the main thread.
    public static func bundleTables(main: Bundle = .main, resources: URL? = Bundle.main.resourceURL) throws(OracleFacetError) -> [Self] {
        do {
            var bundles = [main]
            if let resources {
                let found = try FileManager.checked.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
                bundles += found.filter { $0.pathExtension == "bundle" }.compactMap { Bundle(url: $0) }
            }
            var tables: [Self] = []
            for bundle in bundles {
                let urls = bundle.urls(forResourcesWithExtension: "strings", subdirectory: nil,
                                       localization: bundle.preferredLocalizations.first) ?? []
                for url in urls {
                    tables.append(Self(name: url.lastPathComponent, data: try Data(blockingContentsOf: url)))
                }
            }
            return tables
        } catch {
            throw OracleFacetError("the string tables could not be read: \(error)")
        }
    }
}
#endif
