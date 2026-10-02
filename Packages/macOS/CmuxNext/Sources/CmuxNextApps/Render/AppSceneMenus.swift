import SwiftUI

/// A Menu node: a pull-down of its `menu` items.
struct AppSceneMenuButton: View {
    let model: AppSceneModel
    let id: String
    let node: AppSceneNode

    var body: some View {
        Menu(node.string("title") ?? "") {
            AppSceneMenuItems(items: node.props["menu"]?.arrayValue ?? [], path: []) { path in
                model.send(id, "menu", ["path": .array(path.map { .number(Double($0)) })])
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

/// Menu entries (`{title, destructive?, disabled?, symbol?, children?}` or
/// `{divider: true}`); a pick reports its index path.
struct AppSceneMenuItems: View {
    let items: [AppJSON]
    let path: [Int]
    let pick: ([Int]) -> Void

    var body: some View {
        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
            if item["divider"]?.boolValue == true {
                Divider()
            } else if let children = item["children"]?.arrayValue {
                Menu(item["title"]?.stringValue ?? "") {
                    AppSceneMenuItems(items: children, path: path + [index], pick: pick)
                }
            } else {
                Button(role: item["destructive"]?.boolValue == true ? .destructive : nil) {
                    pick(path + [index])
                } label: {
                    if let symbol = item["symbol"]?.stringValue {
                        Label(item["title"]?.stringValue ?? "", systemImage: symbol)
                    } else {
                        Text(item["title"]?.stringValue ?? "")
                    }
                }
                .disabled(item["disabled"]?.boolValue == true)
            }
        }
    }
}
