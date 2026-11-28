import Foundation

// Screen groups (`screen-groups-v1`, cmux-tui/spec/commands.md
// `create-screen-group` ... `reopen-saved-screen-group`). Screens are named
// by numeric handle. Group changes emit `tree-changed` plus a
// `screen-changed` per member.

// The saved-group requests are generated (bindings.json, family Screens);
// ListSavedScreenGroupsRequest's response stays here.
extension ListSavedScreenGroupsRequest {
    public struct Response: Decodable, Sendable, Equatable {
        public var groups: [SavedScreenGroupSnapshot]
    }
}
