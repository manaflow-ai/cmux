> Diese Übersetzung wurde von Claude erstellt. Verbesserungsvorschläge sind als PR willkommen.

<p align="center"><a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | Deutsch | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.ja.md">日本語</a> | <a href="README.pl.md">Polski</a> | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a></p>

<h1 align="center">cmux</h1>
<p align="center">Ein Ghostty-basiertes macOS-Terminal mit vertikalen Tabs und Benachrichtigungen für AI-Coding-Agenten</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="cmux für macOS herunterladen" width="180" />
  </a>
</p>

<p align="center">
  <img src="./docs/assets/screenshot.png" alt="cmux Screenshot" width="900" />
</p>

## Funktionen

- **Vertikale Tabs** — Die Seitenleiste zeigt Git-Branch, Arbeitsverzeichnis, lauschende Ports und den neuesten Benachrichtigungstext
- **Benachrichtigungsringe** — Bereiche erhalten einen blauen Ring und Tabs leuchten auf, wenn AI-Agenten (Claude Code, OpenCode) Ihre Aufmerksamkeit benötigen
- **Benachrichtigungspanel** — Alle ausstehenden Benachrichtigungen auf einen Blick sehen und zur neuesten ungelesenen springen
- **Geteilte Bereiche** — Horizontale und vertikale Teilung
- **Integrierter Browser** — Teilen Sie einen Browser neben Ihrem Terminal mit einer skriptfähigen API, portiert von [agent-browser](https://github.com/vercel-labs/agent-browser)
- **Skriptfähig** — CLI und Socket-API zum Erstellen von Arbeitsbereichen, Teilen von Bereichen, Senden von Tastenanschlägen und Automatisieren des Browsers
- **Native macOS-App** — Entwickelt mit Swift und AppKit, nicht Electron. Schneller Start, geringer Speicherverbrauch.
- **Ghostty-kompatibel** — Liest Ihre vorhandene `~/.config/ghostty/config` für Themes, Schriftarten und Farben
- **GPU-beschleunigt** — Angetrieben von libghostty für flüssiges Rendering

## Installation

### DMG (empfohlen)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="cmux für macOS herunterladen" width="180" />
</a>

Öffnen Sie die `.dmg`-Datei und ziehen Sie cmux in Ihren Programme-Ordner. cmux aktualisiert sich automatisch über Sparkle, sodass Sie nur einmal herunterladen müssen.

### Homebrew

```bash
brew tap manaflow-ai/cmux
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

Die wesentlichen Ergänzungen sind die Seitenleiste und das Benachrichtigungssystem. Die Seitenleiste hat vertikale Tabs, die Git-Branch, Arbeitsverzeichnis, lauschende Ports und den neuesten Benachrichtigungstext für jeden Arbeitsbereich anzeigen. Das Benachrichtigungssystem erkennt Terminal-Sequenzen (OSC 9/99/777) und bietet eine CLI (`cmux notify`), die Sie in Agent-Hooks für Claude Code, OpenCode usw. einbinden können. Wenn ein Agent wartet, bekommt sein Bereich einen blauen Ring und der Tab leuchtet in der Seitenleiste auf, sodass ich über Teilungen und Tabs hinweg erkennen kann, welcher mich braucht. ⌘⇧U springt zur neuesten ungelesenen Benachrichtigung.

Der integrierte Browser hat eine skriptfähige API, portiert von [agent-browser](https://github.com/vercel-labs/agent-browser). Agenten können den Barrierefreiheitsbaum erfassen, Elementreferenzen erhalten, klicken, Formulare ausfüllen und JS ausführen. Sie können einen Browser-Bereich neben Ihrem Terminal teilen und Claude Code direkt mit Ihrem Entwicklungsserver interagieren lassen.

Alles ist über CLI und Socket-API skriptfähig — Arbeitsbereiche/Tabs erstellen, Bereiche teilen, Tastenanschläge senden, URLs im Browser öffnen.

## Tastenkürzel

### Arbeitsbereiche

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ N | Neuer Arbeitsbereich |
| ⌘ 1–8 | Zu Arbeitsbereich 1–8 springen |
| ⌘ 9 | Zum letzten Arbeitsbereich springen |
| ⌘ ⇧ W | Arbeitsbereich schließen |

### Oberflächen

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ T | Neue Oberfläche |
| ⌘ ⇧ [ | Vorherige Oberfläche |
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

### Browser

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ ⇧ B | Browser in Teilung öffnen |
| ⌘ L | Adressleiste fokussieren |
| ⌘ ] | Vorwärts |
| ⌘ R | Seite neu laden |
| ⌥ ⌘ I | Entwicklertools öffnen |

### Benachrichtigungen

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ ⇧ I | Benachrichtigungspanel anzeigen |
| ⌘ ⇧ U | Zur neuesten ungelesenen springen |

### Suchen

| Tastenkürzel | Aktion |
|----------|--------|
| ⌘ F | Suchen |
| ⌘ G / ⌘ ⇧ G | Nächstes / vorheriges Ergebnis |
| ⌘ ⇧ F | Suchleiste ausblenden |
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
| ⌘ , | Einstellungen |
| ⌘ ⇧ R | Konfiguration neu laden |
| ⌘ Q | Beenden |

## Lizenz

Dieses Projekt ist unter der GNU Affero General Public License v3.0 oder neuer (`AGPL-3.0-or-later`) lizenziert.

Den vollständigen Lizenztext finden Sie in der `LICENSE`-Datei.
