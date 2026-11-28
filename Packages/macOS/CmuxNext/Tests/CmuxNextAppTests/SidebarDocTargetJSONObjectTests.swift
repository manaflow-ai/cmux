import CmuxNextSidebar
import Foundation
import Testing

/// `SidebarDocTarget.jsonObject` is the `sidebar.apply` move's `to`, built field by field so a drop never
/// runs an encoder on the main actor (cmux#59531's class): it must stay the object `encode(to:)` writes.
struct SidebarDocTargetJSONObjectTests {
    @Test(arguments: [
        SidebarDocTarget(section: "pinned"),
        SidebarDocTarget(section: "main", parent: "g1", before: "w2", after: "w1", index: 3),
        SidebarDocTarget(section: "main", after: "w1"),
    ])
    func matchesTheEncodedObject(_ target: SidebarDocTarget) throws {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(target)) as? NSDictionary
        #expect(encoded == (target.jsonObject as NSDictionary))
    }
}
