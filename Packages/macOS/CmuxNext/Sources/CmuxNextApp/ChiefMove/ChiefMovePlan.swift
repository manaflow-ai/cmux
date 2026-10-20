/// The steps of one Chief move. Stub.
struct ChiefMovePlan: Equatable {
    enum Reach: Equatable {
        case cli([String])
        case remote([String])
        case none
    }

    let dryRun: [String]
    let move: [String]
    let reach: Reach

    init(to: String, kind: ChiefMoveTargets.Kind, targetHome: String, tokenFile: String?) {
        (dryRun, move, reach) = ([], [], .none)
    }

    static func targetHome(home: String, userHome: String) -> String { "" }
}
