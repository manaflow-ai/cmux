#!/bin/zsh
# check-notification-extension.sh APP: the built app's notification content extension can
# launch. iOS resolves its context class (_UNNotificationContentExtensionContext) from
# UserNotificationsUI; an extension binary that does not load that framework traps at once
# ("__extensionContextClass != nil") and the long-press view stays blank. Swift's autolink
# alone did not keep it (verify/push-matrix.md, failure 1).
set -euo pipefail
app=${1:?usage: check-notification-extension.sh path/to/CmuxMobileApp.app}
ext=$app/PlugIns/CmuxMobileNotificationContent.appex
bin=$ext/CmuxMobileNotificationContent
[[ -x $bin ]] || { echo "FAIL: no notification content extension in $app"; exit 1; }
point=$(/usr/libexec/PlistBuddy -c 'Print :NSExtension:NSExtensionPointIdentifier' "$ext/Info.plist")
[[ $point == com.apple.usernotifications.content-extension ]] || { echo "FAIL: extension point $point"; exit 1; }
if ! otool -L "$bin" | grep -q '/UserNotificationsUI.framework/UserNotificationsUI'; then
  echo "FAIL: $bin does not link UserNotificationsUI (the content extension traps at launch)"
  exit 1
fi
echo "ok: content extension links UserNotificationsUI"
