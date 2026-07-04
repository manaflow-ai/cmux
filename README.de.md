> Diese Übersetzung wurde von Claude erstellt. Verbesserungsvorschläge sind als PR willkommen.

<h1 align="center">cmux</h1>
<p align="center">Ein Ghostty-basiertes macOS-Terminal mit vertikalen Tabs und Benachrichtigungen für AI-Coding-Agenten</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="cmux für macOS herunterladen" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | Deutsch | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="cmux Screenshot" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Demo-Video</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## Funktionen

<table>
<tr>
<td width="40%" valign="middle">
<h3>Benachrichtigungsringe</h3>
Bereiche erhalten einen blauen Ring und Tabs leuchten auf, wenn Coding-Agenten Ihre Aufmerksamkeit benötigen
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Benachrichtigungsringe" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Benachrichtigungspanel</h3>
Alle ausstehenden Benachrichtigungen auf einen Blick sehen und zur neuesten ungelesenen springen
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Seitenleisten-Benachrichtigungsabzeichen" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Integrierter Browser</h3>
Teilen Sie einen Browser neben Ihrem Terminal mit einer skriptfähigen API, portiert von <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Integrierter Browser" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Vertikale + horizontale Tabs</h3>
Die Seitenleiste zeigt Git-Branch, verknüpften PR-Status/Nummer, Arbeitsverzeichnis, lauschende Ports und den neuesten Benachrichtigungstext. Horizontal und vertikal teilen.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Vertikale Tabs und geteilte Bereiche" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> erstellt einen Arbeitsbereich für eine entfernte Maschine. Browser-Bereiche werden über das entfernte Netzwerk geleitet, sodass localhost einfach funktioniert. Ziehen Sie ein Bild in eine entfernte Sitzung, um es per scp hochzuladen.
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> startet den Teammate-Modus von Claude Code mit einem einzigen Befehl. Teammates erscheinen als native Teilungen mit Seitenleisten-Metadaten und Benachrichtigungen. Kein tmux erforderlich.
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **Browser-Import** — Importieren Sie Cookies, Verlauf und Sitzungen aus Chrome, Firefox, Arc und über 20 weiteren Browsern, damit Browser-Bereiche bereits authentifiziert starten
- **Benutzerdefinierte Befehle** — Definieren Sie projektspezifische Aktionen in [`cmux.json`](https://cmux.com/docs/custom-commands), die über die Befehlspalette gestartet werden
- **Skriptfähig** — CLI und Socket-API zum Erstellen von Arbeitsbereichen, Teilen von Bereichen, Senden von Tastenanschlägen und Automatisieren des Browsers
- **Native macOS-App** — Entwickelt mit Swift und AppKit, nicht Electron. Schneller Start, geringer Speicherverbrauch.
- **Ghostty-kompatibel** — Liest Ihre vorhandene `~/.config/ghostty/config` für Themes, Schriftarten und Farben
- **GPU-beschleunigt** — Angetrieben von libghostty für flüssiges Rendering
- **Tastenkürzel** — [Umfangreiche Tastenkürzel](https://cmux.com/docs/keyboard-shortcuts) für Arbeitsbereiche, Teilungen, Browser und mehr
- **Open Source** — Kostenlos und GPL-lizenziert

## Installation

### DMG (empfohlen)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="cmux für macOS herunterladen" width="180" />
</a>

Öffnen Sie die `.dmg`-Datei und ziehen Sie cmux in Ihren Programme-Ordner. cmux aktualisiert sich automatisch über Sparkle, sodass Sie nur einmal herunterladen müssen.

### Homebrew

```bash
brew install --cask cmux
```

Später aktualisieren:

```bash
brew upgrade --cask cmux
```

Beim ersten Start fordert macOS Sie möglicherweise auf, das Öffnen einer App von einem identifizierten Entwickler zu bestätigen. Klicken Sie auf **Öffnen**, um fortzufahren.

## Warum cmux?

Ich führe viele Claude Code- und Codex-Sitzungen parallel aus. Ich habe Ghostty mit einer Menge geteilter Bereiche verwendet und mich auf die nativen macOS-Benachrichtigungen verlassen, um zu wissen, wann ein Agent mich braucht. Aber der Benachrichtigungstext von Claude Code ist immer nur „Claude is waiting for your input" ohne Kontext, und bei genügend offenen Tabs konnte ich nicht einmal mehr die Titel lesen.

Ich habe einige Coding-Orchestratoren ausprobiert, aber die meisten waren Electron/Tauri-Apps und die Performance hat mich gestört. Ich bevorzuge außerdem das Terminal, da GUI-Orchestratoren einen in ihren Workflow einschließen. Also habe ich cmux als native macOS-App in Swift/AppKit gebaut. Es verwendet libghostty für das Terminal-Rendering und liest Ihre vorhandene Ghostty-Konfiguration für Themes, Schriftarten und Farben.

Die wesentlichen Ergänzungen sind die Seitenleiste und das Benachrichtigungssystem. Die Seitenleiste hat vertikale Tabs, die Git-Branch, verknüpften PR-Status/Nummer, Arbeitsverzeichnis, lauschende Ports und den neuesten Benachrichtigungstext für jeden Arbeitsbereich anzeigen. Das Benachrichtigungssystem erkennt Terminal-Sequenzen (OSC 9/99/777) und bietet eine CLI (`cmux notify`), die Sie in Agent-Hooks für Claude Code, OpenCode usw. einbinden können. Wenn ein Agent wartet, bekommt sein Bereich einen blauen Ring und der Tab leuchtet in der Seitenleiste auf, sodass ich über Teilungen und Tabs hinweg erkennen kann, welcher mich braucht. ⌘⇧U springt zur neuesten ungelesenen Benachrichtigung.

Der integrierte Browser hat eine skriptfähige API, portiert von [agent-browser](https://github.com/vercel-labs/agent-browser). Agenten können den Barrierefreiheitsbaum erfassen, Elementreferenzen erhalten, klicken, Formulare ausfüllen und JS ausführen. Sie können einen Browser-Bereich neben Ihrem Terminal teilen und Claude Code direkt mit Ihrem Entwicklungsserver interagieren lassen.

Alles ist über CLI und Socket-API skriptfähig — Arbeitsbereiche/Tabs erstellen, Bereiche teilen, Tastenanschläge senden, URLs im Browser öffnen.

## The Zen of cmux

cmux schreibt Entwicklern nicht vor, wie sie ihre Werkzeuge nutzen sollen. Es ist ein Terminal und Browser mit einer CLI, und der Rest liegt bei Ihnen.

cmux ist ein Grundbaustein, keine fertige Lösung. Es bietet Ihnen ein Terminal, einen Browser, Benachrichtigungen, Arbeitsbereiche, Teilungen, Tabs und eine CLI, um alles zu steuern. cmux zwingt Sie nicht in eine bestimmte Art, Coding-Agenten zu nutzen. Was Sie mit den Grundbausteinen bauen, ist Ihre Sache.

Die besten Entwickler haben schon immer ihre eigenen Werkzeuge gebaut. Niemand hat bisher die beste Art gefunden, mit Agenten zu arbeiten, und die Teams, die geschlossene Produkte bauen, auch nicht. Die Entwickler, die ihren eigenen Codebasen am nächsten sind, werden es zuerst herausfinden.

Geben Sie einer Million Entwickler komponierbare Grundbausteine, und sie werden gemeinsam die effizientesten Workflows schneller finden, als jedes Produktteam es von oben herab entwerfen könnte.

## Dokumentation

Weitere Informationen zur Konfiguration von cmux finden Sie in [unserer Dokumentation](https://cmux.com/docs/getting-started?utm_source=readme).

## Tastenkürzel

### Arbeitsbereiche

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ N | Neuer Arbeitsbereich |
| ⌘ 1–8 | Zu Arbeitsbereich 1–8 springen |
| ⌘ 9 | Zum letzten Arbeitsbereich springen |
| ⌃ ⌘ ] | Nächster Arbeitsbereich |
| ⌃ ⌘ [ | Vorheriger Arbeitsbereich |
| ⌘ ⇧ W | Arbeitsbereich schließen |
| ⌘ ⇧ R | Arbeitsbereich umbenennen |
| ⌥ ⌘ E | Arbeitsbereichsbeschreibung bearbeiten |
| ⌘ B | Seitenleiste umschalten |
| ⌥ ⌘ B | Rechte Seitenleiste umschalten |
| ⌘ ⇧ E | Fokus der rechten Seitenleiste umschalten |

### Oberflächen

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ T | Neue Oberfläche |
| ⌘ ⇧ ] | Nächste Oberfläche |
| ⌘ ⇧ [ | Vorherige Oberfläche |
| ⌃ Tab | Nächste Oberfläche |
| ⌃ ⇧ Tab | Vorherige Oberfläche |
| ⌃ 1–8 | Zu Oberfläche 1–8 springen |
| ⌃ 9 | Zur letzten Oberfläche springen |
| ⌘ W | Oberfläche schließen |

### Geteilte Bereiche

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ D | Nach rechts teilen |
| ⌘ ⇧ D | Nach unten teilen |
| ⌥ ⌘ ← → ↑ ↓ | Bereich richtungsabhängig fokussieren |
| ⌘ ⇧ H | Fokussierten Bereich aufblitzen |

### Browser

Tastenkürzel für Browser-Entwicklertools folgen den Safari-Standardeinstellungen und sind in `Einstellungen → Tastenkürzel` anpassbar.
Navigationstastenkürzel der Befehlspalette, einschließlich ⌃ P, sind ebenfalls anpassbar und können gelöscht werden, sodass der Tastendruck das aktive Terminal erreicht.

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ ⇧ L | Browser in Teilung öffnen |
| ⌘ L | Adressleiste fokussieren |
| ⌘ [ | Zurück |
| ⌘ ] | Vorwärts |
| ⌘ R | Seite neu laden |
| ⌥ ⌘ I | Entwicklertools umschalten (Safari-Standard) |
| ⌥ ⌘ C | JavaScript-Konsole anzeigen (Safari-Standard) |

### Benachrichtigungen

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ I | Benachrichtigungspanel anzeigen |
| ⌘ ⇧ U | Zur neuesten ungelesenen springen |
| ⌥ ⌘ U | Ungelesen-Status des aktuellen Eintrags umschalten |
| ⌃ ⌘ U | Aktuellen Eintrag als älteste ungelesene markieren und zur nächsten neuesten ungelesenen springen |

### Suchen

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ F | Suchen |
| ⌘ ⇧ F | Im Verzeichnis suchen |
| ⌘ G / ⌥ ⌘ G | Nächstes / vorheriges Ergebnis |
| ⌥ ⌘ ⇧ F | Suchleiste ausblenden |
| ⌘ E | Auswahl für Suche verwenden |

### Terminal

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ K | Scrollback löschen |
| ⌘ C | Kopieren (mit Auswahl) |
| ⌘ V | Einfügen |
| ⌘ + / ⌘ - | Schriftgröße vergrößern / verkleinern |
| ⌘ 0 | Schriftgröße zurücksetzen |

### Fenster

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ ⇧ N | Neues Fenster |
| ⌘ ⇧ O | Vorherige Sitzung erneut öffnen |
| ⌘ , | Einstellungen |
| ⌘ ⇧ , | Konfiguration neu laden |
| ⌘ Q | Beenden |

## Nightly Builds

[cmux NIGHTLY herunterladen](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY ist eine separate App mit eigener Bundle-ID, die neben der stabilen Version läuft. Wird automatisch vom neuesten `main`-Commit gebaut und aktualisiert sich über einen eigenen Sparkle-Feed.

Melden Sie Nightly-Bugs über [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) oder in [#nightly-bugs auf Discord](https://discord.gg/xsgFEVrWCZ).

## Sitzungswiederherstellung

Beim Beenden speichert cmux die aktuelle Sitzung. Beim Neustart stellt cmux den von der
App verwalteten Zustand wieder her:
- Fenster-/Arbeitsbereich-/Bereichs-Layout
- Arbeitsverzeichnisse
- Terminal-Scrollback (bestmöglich)
- Browser-URL und Navigationsverlauf

cmux erstellt keine Prüfpunkte für beliebigen laufenden Prozesszustand. tmux, vim, Shells und
nicht unterstützte Terminal-Apps werden als normale Terminals erneut geöffnet.

Unterstützte Agent-Sitzungen können fortgesetzt werden, wenn Hooks eine native Sitzungs-ID gespeichert haben.
Installieren Sie Hooks nach der Installation der Agent-CLI, damit ihr Binary im `PATH` liegt:

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` installiert die gefundenen unterstützten Agenten und gibt eine Zusammenfassung
der übersprungenen Agenten aus. Zu den unterstützten Wiederaufnahme-Integrationen gehören Claude Code, Codex,
Grok, OpenCode, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy,
Factory und Qoder. Claude Code wird vom cmux Claude-Wrapper übernommen, wenn die Claude-Integration
in den Einstellungen aktiviert ist.

Fortgeschrittene Nutzer und Integrationen können einen eigenen Wiederaufnahmebefehl an die aktuelle
Terminal-Surface binden. Das ist nützlich für Werkzeuge mit eigenem dauerhaftem Zustand,
etwa tmux-Sitzungen oder eigene Agent-CLIs:

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

Die Bindung bleibt mit der cmux-Surface verknüpft. Über öffentliche CLI oder Socket erstellte
Bindungen werden zur Prüfung und manuellen Wiederaufnahme gespeichert, sofern Sie nicht ein
signiertes Befehlspräfix für die automatische Wiederaufnahme freigeben. Freigegebene Präfixe sind
zudem an das Arbeitsverzeichnis und die exakten Umgebungswerte gebunden, sofern vorhanden. Prüfen oder
bearbeiten Sie Freigaben unter **Einstellungen > Terminal > Wiederaufnahmebefehle**. cmux führt nur
Wiederaufnahme-Bindungen automatisch aus, die es als vertrauenswürdig markiert, etwa aus laufenden
Prozessen erkannte tmux-Bindungen oder vom Nutzer freigegebene Präfixe. Sensible Umgebungsvariablen
wie Tokens, Passwörter, Secrets und API-Keys werden verworfen, bevor eine Wiederaufnahme-Bindung
gespeichert wird.

Um wiederhergestellte Agent-Terminals inaktiv zu lassen, anstatt ihre Wiederaufnahmebefehle automatisch auszuführen,
deaktivieren Sie **Einstellungen > Terminal > Agent-Sitzungen beim erneuten Öffnen fortsetzen** oder setzen Sie dies in
`~/.config/cmux/cmux.json`:

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

Dies deaktiviert nur die automatischen Agent-Wiederaufnahmebefehle. cmux stellt weiterhin das gespeicherte Layout,
die Arbeitsverzeichnisse, den Scrollback und den Browserverlauf wieder her.

Wenn Sie den zuletzt gespeicherten Snapshot manuell erneut anwenden müssen, verwenden Sie:
- `Ablage > Vorherige Sitzung erneut öffnen`
- `⌘ ⇧ O`
- `cmux restore-session`

Im Hintergrund schreibt cmux einen versionierten Snapshot unter
`~/Library/Application Support/cmux/`, und Agent-Hooks schreiben Sitzungszuordnungen
unter `~/.cmuxterm/`. Bei der Wiederherstellung baut cmux zuerst das Layout neu auf und führt dann den
nativen Wiederaufnahmebefehl des unterstützten Agenten aus, wenn die automatische Agent-Wiederaufnahme aktiviert ist.

Lesen Sie die vollständige Anleitung unter <https://cmux.com/docs/session-restore>.

## FAQ

### Wie verhält sich cmux zu Ghostty?

cmux ist kein Fork von Ghostty. Es verwendet [libghostty](https://github.com/ghostty-org/ghostty) als Bibliothek für das Terminal-Rendering, so wie Apps WebKit für Webansichten verwenden. Ghostty ist ein eigenständiges Terminal; cmux ist eine andere App, die auf dessen Rendering-Engine aufbaut.

### Welche Plattformen werden unterstützt?

Vorerst nur macOS. cmux ist eine native Swift + AppKit-App.

### Gibt es eine iOS-App?

Ja, in der Beta. Koppeln Sie Ihr iPhone im Mobile-Connect-Fenster mit Ihrem Mac und verbinden Sie sich von Ihrem Telefon aus mit Ihren Terminals, mit optionaler Weiterleitung von Terminal-Benachrichtigungen. Sie wird über TestFlight als cmux BETA ausgeliefert. Siehe die [iOS-Dokumentation](https://cmux.com/docs/ios).

### Mit welchen Coding-Agenten funktioniert cmux?

Mit allen. cmux ist ein Terminal, also funktioniert jeder Agent, der in einem Terminal läuft, sofort: Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor Agent und alles andere, was Sie über die Kommandozeile starten können.

### Kann cmux mehrere Agenten und Subagenten orchestrieren?

Ja. Wenn ein Agent Subagenten oder Teammates erzeugt, verwandelt cmux sie in native Bereiche und Teilungen statt in verborgene Hintergrundprozesse. Es unterstützt [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) und die Multi-Modell-Orchestrierung von [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode), sodass jeder Agent eines Laufs sichtbar und steuerbar ist.

### Kann ich cmux mit entfernten Maschinen verwenden?

Ja. Öffnen Sie Arbeitsbereiche über SSH und verbinden Sie sich mit entfernten tmux-Sitzungen, sodass Agenten auf einem entfernten Host laufen können, während Sie sie von cmux aus steuern. Siehe [SSH und Remote](https://cmux.com/docs/ssh).

### Wie funktionieren Benachrichtigungen?

Wenn ein Prozess Aufmerksamkeit benötigt, zeigt cmux Benachrichtigungsringe um Bereiche, Ungelesen-Abzeichen in der Seitenleiste, ein Benachrichtigungs-Popover und eine macOS-Desktop-Benachrichtigung. Diese werden automatisch über standardisierte Terminal-Escape-Sequenzen (OSC 9/99/777) ausgelöst, oder Sie können sie mit der [cmux-CLI](https://cmux.com/docs/notifications#cli-usage) und [Agent-Hooks](https://cmux.com/docs/notifications#integration-examples) auslösen. Jeder Agent, der Hooks oder OSC unterstützt, funktioniert, einschließlich Claude Code, Codex, OpenCode und pi.

### Ist cmux programmierbar?

Ja. Jede Aktion ist über die cmux-CLI und einen Unix-Socket verfügbar: Arbeitsbereiche erstellen, geteilte Bereiche öffnen, Eingaben senden, Bildschirminhalte lesen, Screenshots erstellen und den integrierten Browser steuern. Siehe die [CLI-Referenz](https://cmux.com/docs/api) und die [Browser-Automatisierung](https://cmux.com/docs/browser-automation)-Dokumentation.

### Was kann der integrierte Browser?

cmux kann einen echten Browser-Bereich neben Ihrem Terminal teilen, und er ist vollständig programmierbar: navigieren, das DOM erfassen, klicken, tippen, JavaScript ausführen sowie Konsolen- und Netzwerkaktivität über dieselbe Socket-API lesen. Agenten nutzen ihn, um ihre eigenen Web-Änderungen zu überprüfen, ohne cmux zu verlassen. Siehe [Browser-Automatisierung](https://cmux.com/docs/browser-automation).

### Hat cmux Skills?

Ja. Skills sind wiederverwendbare Workflows, die Sie jedem in cmux laufenden Agenten geben können, für Dinge wie CLI-Steuerung, Arbeitsbereichs-Automatisierung, Einstellungen und Browser-Surfaces. Durchstöbern Sie die offene Sammlung unter [cmux-skills](https://github.com/manaflow-ai/cmux-skills) oder lesen Sie die [Skills-Dokumentation](https://cmux.com/docs/skills).

### Kann ich Tastenkürzel anpassen?

Terminal-Tastenbelegungen werden aus Ihrer Ghostty-Konfigurationsdatei (`~/.config/ghostty/config`) gelesen. cmux-spezifische Tastenkürzel (Arbeitsbereiche, Teilungen, Browser, Benachrichtigungen) können in den Einstellungen angepasst werden. Eine vollständige Liste finden Sie unter [Standard-Tastenkürzel](https://cmux.com/docs/keyboard-shortcuts).

### Kann ich cmux anpassen?

Ja. Das Terminal-Rendering verwendet Ihre Ghostty-Konfiguration, sodass Themes, Schriftarten, Farben und Cursor direkt übernommen werden. cmux' eigene Einstellungen in `~/.config/cmux/cmux.json` steuern die Seitenleiste, die Tab-Leiste, geteilte Bereiche und das Verhalten, und jedes [Tastenkürzel](https://cmux.com/docs/keyboard-shortcuts) ist editierbar. Siehe [Konfiguration](https://cmux.com/docs/configuration).

### Werden meine Sitzungen gespeichert?

Ja. cmux stellt Ihre Fenster, Arbeitsbereiche, Bereiche, Arbeitsverzeichnisse und den Scrollback beim erneuten Öffnen wieder her, und der Zustand übersteht einen kompletten Computer-Neustart, nicht nur das Beenden der App. Agent-Sitzungen wie Claude Code, Codex und OpenCode kommen ebenfalls zurück. Siehe [Sitzungswiederherstellung](https://cmux.com/docs/session-restore).

### Wie schneidet es im Vergleich zu tmux ab?

tmux ist ein Terminal-Multiplexer, der in jedem Terminal läuft. cmux ist eine native macOS-App mit GUI: vertikale Tabs, geteilte Bereiche, ein eingebetteter Browser und eine Socket-API, alles eingebaut, ohne Konfigurationsdateien oder Prefix-Tasten. Trotzdem nutzen viele Leute cmux gerne zusammen mit SSH und tmux, und cmux kann sich nativ mit Ihren entfernten tmux-Sitzungen verbinden ([Beta](https://cmux.com/docs/remote-tmux)).

### Ist cmux kostenlos?

Ja, cmux ist kostenlos nutzbar. Der Quellcode ist auf [GitHub](https://github.com/manaflow-ai/cmux) verfügbar.

### Wie kann ich cmux unterstützen?

cmux ist kostenlos und Open Source und wird es immer bleiben. Wenn Sie die Entwicklung unterstützen und frühen Zugang zu kommenden Funktionen erhalten möchten, einschließlich cmux AI, der iOS-App und Cloud-VMs, schauen Sie sich die [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition) an.

### Ich habe einen Feature-Wunsch oder einen Bug gefunden?

Wir möchten davon hören. Öffnen Sie eine [Issue](https://github.com/manaflow-ai/cmux/issues) oder einen [Pull Request](https://github.com/manaflow-ai/cmux/pulls) auf GitHub, oder [schreiben Sie uns eine E-Mail](mailto:founders@manaflow.com?subject=cmux%20feature%20request).

## Star-Verlauf

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Mitwirken

Möglichkeiten, sich einzubringen:

- Folgen Sie uns auf X für Updates [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen) und [@austinywang](https://x.com/austinywang)
- Nehmen Sie an der Diskussion auf [Discord](https://discord.gg/xsgFEVrWCZ) teil
- Erstellen Sie [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) und beteiligen Sie sich an [Diskussionen](https://github.com/manaflow-ai/cmux/discussions)
- Lassen Sie uns wissen, was Sie mit cmux bauen

## Community

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

<p>
  <strong>WeChat:</strong> Scannen Sie den QR-Code, um der Community beizutreten.<br />
  <img src="./docs/assets/wechat-community-qr.jpg" alt="WeChat-QR-Code zum Beitritt zur cmux-Community" width="240" />
</p>

## Founder's Edition

cmux ist kostenlos, Open Source und wird es immer sein. Wenn Sie die Entwicklung unterstützen und frühen Zugang zu kommenden Funktionen erhalten möchten:

**[Founder's Edition erhalten](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Priorisierte Feature-Requests/Bugfixes**
- **Früher Zugang: cmux AI, das Ihnen Kontext zu jedem Arbeitsbereich, Tab und Panel gibt**
- **Früher Zugang: iOS-App mit zwischen Desktop und Telefon synchronisierten Terminals**
- **Früher Zugang: Cloud-VMs**
- **Früher Zugang: Sprachmodus**
- **Meine persönliche iMessage/WhatsApp**

## Lizenz

cmux ist Open Source unter [GPL-3.0-or-later](LICENSE).

Wenn Ihre Organisation GPL nicht einhalten kann, ist eine kommerzielle Lizenz verfügbar. Kontaktieren Sie [founders@manaflow.com](mailto:founders@manaflow.com) für Details.
