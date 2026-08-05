import Foundation
import Testing

@testable import CMUXMobileCore

struct MobileWorkspaceLayoutTests {
    private func layout(
        version: Int = 7,
        ratio: Double = 0.4,
        focusedPaneID: String? = "pane-left",
        selectedSurfaceID: String? = "surface-shell",
        title: String = "Shell",
        type: String = "terminal"
    ) -> MobileWorkspaceLayout {
        MobileWorkspaceLayout(
            version: version,
            focusedPaneID: focusedPaneID,
            root: .split(
                MobileWorkspaceLayoutSplit(
                    id: "split-root",
                    orientation: .horizontal,
                    ratio: ratio,
                    first: .pane(
                        MobileWorkspaceLayoutPane(
                            id: "pane-left",
                            selectedSurfaceID: selectedSurfaceID,
                            surfaces: [
                                MobileWorkspaceLayoutSurface(
                                    id: "surface-shell",
                                    type: type,
                                    title: title
                                )
                            ]
                        )
                    ),
                    second: .pane(
                        MobileWorkspaceLayoutPane(
                            id: "pane-right",
                            selectedSurfaceID: "surface-preview",
                            surfaces: [
                                MobileWorkspaceLayoutSurface(
                                    id: "surface-preview",
                                    type: "browser",
                                    title: "Preview"
                                )
                            ]
                        )
                    )
                )
            )
        )
    }

    private func topologySignature(_ layout: MobileWorkspaceLayout) -> Int {
        var hasher = Hasher()
        layout.hashTopology(into: &hasher)
        return hasher.finalize()
    }

    @Test func roundTripsExactLayoutV1WireShape() throws {
        let original = layout()
        let object = try MobileSyncFrameCoder().jsonObject(from: original)

        #expect(object["version"] as? Int == 7)
        #expect(object["focused_pane_id"] as? String == "pane-left")
        let root = try #require(object["root"] as? [String: Any])
        #expect(root["kind"] as? String == "split")
        #expect(root["orientation"] as? String == "horizontal")
        #expect(root["ratio"] as? Double == 0.4)
        let first = try #require(root["first"] as? [String: Any])
        #expect(first["kind"] as? String == "pane")
        #expect(first["selected_surface_id"] as? String == "surface-shell")
        let surfaces = try #require(first["surfaces"] as? [[String: Any]])
        #expect(surfaces.first?["id"] as? String == "surface-shell")
        #expect(surfaces.first?["type"] as? String == "terminal")
        #expect(surfaces.first?["title"] as? String == "Shell")

        let decoded = try MobileSyncFrameCoder().decode(
            MobileWorkspaceLayout.self,
            fromJSONObject: object
        )
        #expect(decoded == original)
    }

    @Test func topologyHashIgnoresPresentationOnlyChanges() {
        let baseline = topologySignature(layout())

        #expect(topologySignature(layout(version: 99)) == baseline)
        #expect(topologySignature(layout(ratio: 0.8)) == baseline)
        #expect(topologySignature(layout(title: "Renamed")) == baseline)
        #expect(topologySignature(layout(type: "browser")) == baseline)
    }

    @Test func topologyHashTracksFocusAndPaneSelection() {
        let baseline = topologySignature(layout())

        #expect(topologySignature(layout(focusedPaneID: "pane-right")) != baseline)
        #expect(topologySignature(layout(selectedSurfaceID: nil)) != baseline)
    }
}
