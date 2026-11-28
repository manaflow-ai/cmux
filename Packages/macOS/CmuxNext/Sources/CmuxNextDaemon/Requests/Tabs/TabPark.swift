import Foundation

/// `park-tabs` (`tab-park-v1`): ends the shells of terminal tabs but keeps
/// the tabs as keep-layout tabs (`relaunch: {cwd}`), each started again by
/// `restart-tab`. The classic migration parks the workspaces it brings over
/// in the background, so their terminals start only when first shown.
/// Tabs that are not terminals, or whose shell already ended, are skipped.
extension ParkTabsRequest {
    public struct Response: Decodable, Sendable, Equatable {
        /// The tabs whose terminal was parked.
        public var parked: [SurfaceID]

        public init(parked: [SurfaceID]) {
            self.parked = parked
        }
    }
}
