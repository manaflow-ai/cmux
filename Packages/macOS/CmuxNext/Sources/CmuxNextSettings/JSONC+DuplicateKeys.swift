/// Members whose keys are equal strings (`{"a": 1, "a": 2}`, or U+00E9 and U+0065 U+0301): the last in the
/// document is the one that reads, as in Chromium's reader (base/json/json_parser.cc, `ConsumeDictionary` sets
/// each key in turn), and the one ``JSONC/setting(_:at:in:)`` and ``JSONC/removing(_:in:)`` edit.
extension JSONC {
    /// `strict` without the members a later member with an equal key shadows, so the JSON reader (whose
    /// dictionaries keep keys that are distinct NSStrings apart, in no set order) sees one member per key.
    /// Text the edit parser does not take goes to the reader unchanged, which then refuses it.
    static func droppingShadowedMembers(_ strict: String) -> String {
        let bytes = Array(strict.utf8)
        guard let root = try? parseRoot(bytes) else { return strict }
        var edits: [Edit] = []
        collectShadowedMembers(in: root, into: &edits)
        return edits.isEmpty ? strict : apply(edits, to: bytes)
    }

    /// Removals of the shadowed members under `node`. A shadowed member is never its object's last, so a comma
    /// follows it (strict text has no trailing commas); what it holds goes with it and is not visited.
    private static func collectShadowedMembers(in node: Node, into edits: inout [Edit]) {
        switch node {
        case .scalar:
            return
        case .array(let items):
            for item in items { collectShadowedMembers(in: item, into: &edits) }
        case .object(let object):
            var kept = Set<String>()
            for member in object.members.reversed() {
                if kept.insert(member.key).inserted {
                    collectShadowedMembers(in: member.node, into: &edits)
                } else if let comma = member.commaAfter {
                    edits.append(Edit(range: member.keyStart..<(comma + 1), text: ""))
                }
            }
        }
    }

    /// `source` without the last member at `path` (the one ``parse(_:)`` reads), or nil when there is none.
    static func removingLast(_ path: [String], in source: String) throws -> String? {
        let bytes = Array(source.utf8)
        guard let root = try parseRoot(bytes) else { return nil }
        guard case .object(var object) = root else { throw Failure.rootIsNotObject }
        for key in path.dropLast() {
            guard let member = object.members.last(where: { $0.key == key }),
                  case .object(let child) = member.node else { return nil }
            object = child
        }
        guard let index = object.members.lastIndex(where: { $0.key == path.last }) else { return nil }
        return apply(removalEdits(memberAt: index, in: object, bytes: bytes), to: bytes)
    }
}
