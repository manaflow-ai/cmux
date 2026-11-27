import SwiftUI

extension cmuxApp {
    /// The top-level Cloud menu: account and team, create verbs, every machine
    /// with its verbs, and Cloud tools. Same entries as the status item's Cloud
    /// section (``CloudMenuContent``), laid out for the menu bar.
    @CommandsBuilder
    var cloudCommands: some Commands {
        let model = CloudMenuModel.shared
        if model.isFeatureEnabled {
            CommandMenu(String(localized: "menu.cloud.title", defaultValue: "Cloud")) {
                if let appDelegate = AppDelegate.shared {
                    // Reading the model and the account flow here registers
                    // Observation, so the open menu updates when a read lands.
                    let _ = model.revision
                    CloudMenuEntriesView(entries: CloudMenuContent.entries(
                        appDelegate.cloudMenuContext(model: model),
                        actions: appDelegate.cloudMenuActions(model: model, fromStatusItem: false),
                        layout: .mainMenu
                    ))
                }
            }
        }
    }
}
