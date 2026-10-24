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
# The content extension reads the push key and the Macs' trust record (PushTrustGate) to
# open a sealed push again; without the shared push keychain group every sealed push
# shows "Open cmux to see this notification" and a terminal one gets no Reply (PR B, found
# live). Simulator builds embed entitlements in the binary's __entitlements section.
ent=$( (codesign -d --entitlements - --xml "$ext" 2>/dev/null; strings -a "$bin") | tr -d '\n\t ' )
if ! grep -q '<key>keychain-access-groups</key><array><string>[^<]*\.push</string>' <<<"$ent"; then
  echo "FAIL: the content extension has no shared push keychain group (sealed pushes can't open in the long look)"
  exit 1
fi
echo "ok: content extension shares the push keychain group"

