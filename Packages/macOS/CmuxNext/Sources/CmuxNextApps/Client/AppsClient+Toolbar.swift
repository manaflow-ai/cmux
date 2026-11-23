public import Foundation

/// The toolbar band's app items (`contributes.toolbarItems`). The daemon decides which apps contribute
/// and in what order (cmux-tui-core `apps/toolbar.rs`); the client keeps its answer, lists again on every
/// `apps-changed` (an install, a hide, a saved local manifest), and runs a click through `apps-run` as the
/// person. A daemon that does not serve the list, or an empty one, leaves the band as it was built in.
extension AppsClient {
    /// Lists the items again; the band redraws only when they changed.
    func refreshToolbar() {
        guard availability.isAvailable else { return }
        toolbarListing?.cancel()
        // task-owner: the client (cancelled by the next list and on disconnect); one request per apps-changed
        toolbarListing = Task { [weak self, transport] in
            let items: [AppToolbarContribution]
            do throws(AppsTransportError) { items = try await transport.toolbarItems() } catch { items = [] }
            guard !Task.isCancelled, let self, items != toolbarItems else { return }
            toolbarItems = items
        }
    }

    /// Runs a click on `item` (or on one row of its menu) as the person. A refusal goes to the app's log,
    /// as a palette run's does to the action's failure.
    public func runToolbarItem(_ item: AppToolbarContribution, entry: AppToolbarContribution.Entry? = nil) {
        guard let op = entry?.op ?? item.op else { return }
        let args = entry?.args ?? item.args
        // task-owner: one user click; ends with the op's reply
        Task { [weak self] in
            do throws(AppsClientError) {
                _ = try await self?.run(app: item.app, op: op, args: args, origin: .user)
            } catch {
                self?.appendLog(item.app, level: "error", message: "\(op): \(error.description)", date: Date())
            }
        }
    }
}
