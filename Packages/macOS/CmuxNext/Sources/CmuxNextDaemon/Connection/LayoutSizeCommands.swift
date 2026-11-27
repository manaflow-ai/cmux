/// The daemon commands that send the values one resize gesture ends with, all under the gesture's one
/// `transaction` (one undo step):
/// - One value goes as its own command (`set-split-ratio`, `set-viewport-pane-width`).
/// - More values go to a daemon with `layout-sizes-batch-v1` as one `set-layout-sizes`: one commit, every value
///   or none.
/// - A daemon without it gets each value's own command in order, and so does a change of more values than one
///   `set-layout-sizes` takes. These are separate commits: a value the daemon refuses ends the list and leaves
///   the values before it applied.
///
/// A separate type keeps `DaemonConnection`'s command file within its size budget.
public struct LayoutSizeCommands: Sendable, Equatable {
    /// One command of the list.
    public enum Command: Sendable, Equatable {
        case batch([SetLayoutSizesRequest.Value])
        case single(SetLayoutSizesRequest.Value)
    }

    public let commands: [Command]
    public let transaction: UInt64

    /// - Parameters:
    ///   - values: The gesture's ended values, in the order they apply.
    ///   - transaction: The gesture's resize transaction on the connection.
    ///   - batch: The daemon serves `layout-sizes-batch-v1`.
    public init(_ values: [SetLayoutSizesRequest.Value], transaction: UInt64, batch: Bool) {
        self.transaction = transaction
        commands = batch && (2...SetLayoutSizesRequest.limit).contains(values.count) ? [.batch(values)] : values.map(Command.single)
    }

    /// The name the commands run under: the one command's own name, or `set-layout-sizes` for a list.
    public var label: String {
        guard commands.count == 1, case let .single(value)? = commands.first else { return SetLayoutSizesRequest.command }
        switch value {
        case .ratio: return SetSplitRatioRequest.command
        case .width: return SetColumnWidthRequest.command
        }
    }

    /// Sends the commands in order. The first one the daemon refuses throws, and nothing after it goes.
    public func send(on connection: DaemonConnection) async throws {
        for command in commands {
            switch command {
            case let .batch(values):
                _ = try await connection.request(SetLayoutSizesRequest(values: values, transaction: transaction))
            case let .single(.ratio(split, ratio)):
                try await connection.setSplitRatio(split, ratio: ratio, transaction: transaction)
            case let .single(.width(pane, width)):
                try await connection.setColumnWidth(of: pane, width: width, transaction: transaction)
            }
        }
    }
}
