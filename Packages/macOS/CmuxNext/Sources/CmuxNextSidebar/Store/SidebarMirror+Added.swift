import Foundation

extension SidebarMirror {
    /// The items `ops` (a JSON array, as the mirror stamped it) add, each with what it shows: `item.add` names the id
    /// and the body. A change's rows hold such an item at once; the confirmed records only after its batch.
    nonisolated static func addedRefs(in ops: Data) -> [String: LayoutItemRef] {
        guard let list = (try? JSONSerialization.jsonObject(with: ops)) as? [[String: Any]] else { return [:] }
        var refs: [String: LayoutItemRef] = [:]
        for op in list where op["op"] as? String == "item.add" {
            guard let item = op["item"] as? [String: Any], let id = item["id"] as? String, let body = item["body"],
                  let data = try? JSONSerialization.data(withJSONObject: ["id": id, "section": "", "body": body]),
                  let wire = try? JSONDecoder().decode(SidebarDocWire.Item.self, from: data) else { continue }
            refs[id] = SidebarDocProjection.ref(wire.record.body, id: id)
        }
        return refs
    }
}
