public enum BrowserCommandMethod {
    public static func history(_ command: String) -> SocketMethod? {
        historyMethods[command]
    }

    public static func elementAction(_ command: String) -> SocketMethod? {
        elementActionMethods[command]
    }

    public static func keyboardAction(_ command: String) -> SocketMethod? {
        keyboardActionMethods[command]
    }

    public static func getter(_ command: String) -> SocketMethod? {
        getterMethods[command]
    }

    public static func predicate(_ command: String) -> SocketMethod? {
        predicateMethods[command]
    }

    private static let historyMethods: [String: SocketMethod] = [
        "back": .browserBack,
        "forward": .browserForward,
        "reload": .browserReload,
    ]

    private static let elementActionMethods: [String: SocketMethod] = [
        "click": .browserClick,
        "dblclick": .browserDblClick,
        "hover": .browserHover,
        "focus": .browserFocus,
        "check": .browserCheck,
        "uncheck": .browserUncheck,
        "scrollintoview": .browserScrollIntoView,
        "scrollinto": .browserScrollIntoView,
        "scroll-into-view": .browserScrollIntoView,
    ]

    private static let keyboardActionMethods: [String: SocketMethod] = [
        "press": .browserPress,
        "key": .browserPress,
        "keydown": .browserKeyDown,
        "keyup": .browserKeyUp,
    ]

    private static let getterMethods: [String: SocketMethod] = [
        "text": .browserGetText,
        "html": .browserGetHTML,
        "value": .browserGetValue,
        "attr": .browserGetAttr,
        "count": .browserGetCount,
        "box": .browserGetBox,
        "styles": .browserGetStyles,
    ]

    private static let predicateMethods: [String: SocketMethod] = [
        "visible": .browserIsVisible,
        "enabled": .browserIsEnabled,
        "checked": .browserIsChecked,
    ]
}
