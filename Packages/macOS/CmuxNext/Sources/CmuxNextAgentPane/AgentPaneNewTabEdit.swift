/// What the New Tab page changed about itself; the App saves it as Settings would. The style
/// switch's pick (`newTab.setTemplate`), its edit mode's ✕, drag and + (`newTab.editWidgets`;
/// right-click the page > Edit New Tab), and its dots' quick actions (`{edit: "show"}` or
/// `"remove"`, webviews newtab/tabDots.ts).
public nonisolated enum AgentPaneNewTabEdit: Sendable, Equatable {
    /// The style switch (`{template}`): the template to save as `tabs.newTabTemplate` (the App
    /// checks the value).
    case template(String)
    /// ✕ on a widget, or a dot without it (`{edit: "remove", widget}`): turn it off.
    case remove(String)
    /// A dot with a widget (`{edit: "show", widget}`; the second dot's quick actions): turn it on.
    case show(String)
    /// A drag (`{edit: "order", order}`): the movable widgets in their new order.
    case order([String])
    /// + (`{edit: "add"}`): App Store Features on New Tab, where the widgets that are off are.
    case add

    /// The page method that sent it.
    var method: String {
        if case .template = self { "newTab.setTemplate" } else { "newTab.editWidgets" }
    }

    /// `newTab.editWidgets`' params, or nil for a bad one. A widget name is a short identifier;
    /// the App checks it against the schema.
    init?(widgetParams params: [String: Any]?) {
        let isName = { (name: String) in (1...32).contains(name.count) && name.allSatisfy { $0.isASCII && $0.isLetter } }
        switch params?["edit"] as? String {
        case "remove":
            guard let widget = params?["widget"] as? String, isName(widget) else { return nil }
            self = .remove(widget)
        case "show":
            guard let widget = params?["widget"] as? String, isName(widget) else { return nil }
            self = .show(widget)
        case "order":
            guard let order = params?["order"] as? [String], order.count <= 16, order.allSatisfy(isName) else { return nil }
            self = .order(order)
        case "add": self = .add
        default: return nil
        }
    }
}
