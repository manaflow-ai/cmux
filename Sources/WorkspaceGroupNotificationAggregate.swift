struct WorkspaceGroupNotificationAggregate {
    var memberCount: Int = 0
    var unreadWorkspaceCount: Int = 0
    var unreadNotificationCount: Int = 0

    mutating func add(_ other: WorkspaceGroupNotificationAggregate) {
        memberCount += other.memberCount
        unreadWorkspaceCount += other.unreadWorkspaceCount
        unreadNotificationCount += other.unreadNotificationCount
    }
}
