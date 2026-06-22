> To tłumaczenie zostało wygenerowane przez Claude. Jeśli masz sugestie dotyczące poprawek, otwórz PR.

<h1 align="center">cmux</h1>
<p align="center">Terminal macOS oparty na Ghostty z pionowymi kartami i powiadomieniami dla agentów kodowania AI</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Pobierz cmux dla macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.ja.md">日本語</a> | <a href="README.vi.md">Tiếng Việt</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | Polski | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a> | <a href="README.km.md">ភាសាខ្មែរ</a> | <a href="README.uk.md">Українська</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
  <a href="https://github.com/manaflow-ai/cmux"><img src="https://img.shields.io/github/stars/manaflow-ai/cmux?style=flat&logo=github&label=stars&color=4c71f2" alt="GitHub stars" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="Zrzut ekranu cmux" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Film demonstracyjny</a> · <a href="https://cmux.com/blog/zen-of-cmux">The Zen of cmux</a>
</p>

## Funkcje

<table>
<tr>
<td width="40%" valign="middle">
<h3>Pierścienie powiadomień</h3>
Panele otrzymują niebieski pierścień, a karty podświetlają się, gdy agenci kodowania potrzebują Twojej uwagi
</td>
<td width="60%">
<img src="./docs/assets/notification-rings.png" alt="Pierścienie powiadomień" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Panel powiadomień</h3>
Zobacz wszystkie oczekujące powiadomienia w jednym miejscu, przeskocz do najnowszego nieprzeczytanego
</td>
<td width="60%">
<img src="./docs/assets/sidebar-notification-badge.png" alt="Znacznik powiadomień w pasku bocznym" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Wbudowana przeglądarka</h3>
Podziel przeglądarkę obok terminala ze skryptowalnym API przeniesionym z <a href="https://github.com/vercel-labs/agent-browser">agent-browser</a>
</td>
<td width="60%">
<img src="./docs/assets/built-in-browser.png" alt="Wbudowana przeglądarka" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Pionowe + poziome karty</h3>
Pasek boczny pokazuje gałąź git, status/numer powiązanego PR, katalog roboczy, nasłuchujące porty i tekst ostatniego powiadomienia. Podziały poziome i pionowe.
</td>
<td width="60%">
<img src="./docs/assets/vertical-horizontal-tabs-and-splits.png" alt="Pionowe karty i podzielone panele" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>SSH</h3>
<code>cmux ssh user@remote</code> tworzy przestrzeń roboczą dla zdalnej maszyny. Panele przeglądarki kierowane są przez zdalną sieć, więc localhost po prostu działa. Przeciągnij obraz do sesji zdalnej, aby przesłać go przez scp.
</td>
<td width="60%">
<img src="./docs/assets/ssh.png" alt="cmux SSH" width="100%" />
</td>
</tr>
<tr>
<td width="40%" valign="middle">
<h3>Claude Code Teams</h3>
<code>cmux claude-teams</code> uruchamia tryb współpracy Claude Code jednym poleceniem. Współpracownicy pojawiają się jako natywne podziały z metadanymi w pasku bocznym i powiadomieniami. Nie wymaga tmux.
</td>
<td width="60%">
<img src="./docs/assets/claude-code-teams.png" alt="Claude Code Teams" width="100%" />
</td>
</tr>
</table>

- **Import z przeglądarki** — Importuj ciasteczka, historię i sesje z Chrome, Firefox, Arc i ponad 20 innych przeglądarek, aby panele przeglądarki uruchamiały się z autoryzacją
- **Własne polecenia** — Definiuj akcje specyficzne dla projektu w [`cmux.json`](https://cmux.com/docs/custom-commands), które uruchamiają się z palety poleceń
- **Skryptowalny** — CLI i socket API do tworzenia przestrzeni roboczych, dzielenia paneli, wysyłania naciśnięć klawiszy i automatyzacji przeglądarki
- **Natywna aplikacja macOS** — Zbudowana w Swift i AppKit, nie Electron. Szybki start, niskie zużycie pamięci.
- **Kompatybilny z Ghostty** — Odczytuje istniejącą konfigurację `~/.config/ghostty/config` dla motywów, czcionek i kolorów
- **Akceleracja GPU** — Napędzany przez libghostty dla płynnego renderowania
- **Skróty klawiszowe** — [Rozbudowane skróty](https://cmux.com/docs/keyboard-shortcuts) dla przestrzeni roboczych, podziałów, przeglądarki i więcej
- **Open source** — Darmowy i na licencji GPL

## Instalacja

### DMG (zalecane)

<a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
  <img src="./docs/assets/macos-badge.png" alt="Pobierz cmux dla macOS" width="180" />
</a>

Otwórz plik `.dmg` i przeciągnij cmux do folderu Aplikacje. cmux aktualizuje się automatycznie przez Sparkle, więc musisz pobrać go tylko raz.

### Homebrew

```bash
brew tap manaflow-ai/cmux
brew install --cask cmux
```

Aby zaktualizować później:

```bash
brew upgrade --cask cmux
```

Przy pierwszym uruchomieniu macOS może poprosić o potwierdzenie otwarcia aplikacji od zidentyfikowanego dewelopera. Kliknij **Otwórz**, aby kontynuować.

## Dlaczego cmux?

Uruchamiam wiele sesji Claude Code i Codex równolegle. Używałem Ghostty z masą podzielonych paneli i polegałem na natywnych powiadomieniach macOS, żeby wiedzieć, kiedy agent mnie potrzebuje. Ale treść powiadomienia Claude Code to zawsze tylko „Claude is waiting for your input" bez kontekstu, a przy wystarczającej liczbie otwartych kart nie mogłem nawet przeczytać tytułów.

Wypróbowałem kilka orkiestratorów kodowania, ale większość z nich to aplikacje Electron/Tauri, a ich wydajność mi przeszkadzała. Po prostu wolę też terminal, ponieważ orkiestratory GUI zamykają cię w swoim przepływie pracy. Dlatego zbudowałem cmux jako natywną aplikację macOS w Swift/AppKit. Używa libghostty do renderowania terminala i odczytuje istniejącą konfigurację Ghostty dla motywów, czcionek i kolorów.

Główne dodatki to pasek boczny i system powiadomień. Pasek boczny ma pionowe karty pokazujące gałąź git, status/numer powiązanego PR, katalog roboczy, nasłuchujące porty i tekst ostatniego powiadomienia dla każdej przestrzeni roboczej. System powiadomień przechwytuje sekwencje terminala (OSC 9/99/777) i ma CLI (`cmux notify`), który można podpiąć do hooków agentów dla Claude Code, OpenCode itp. Gdy agent czeka, jego panel otrzymuje niebieski pierścień, a karta podświetla się w pasku bocznym, więc mogę powiedzieć, który mnie potrzebuje, niezależnie od podziałów i kart. Cmd+Shift+U przeskakuje do najnowszego nieprzeczytanego.

Wbudowana przeglądarka ma skryptowalny API przeniesiony z [agent-browser](https://github.com/vercel-labs/agent-browser). Agenci mogą wykonać migawkę drzewa dostępności, uzyskać referencje elementów, klikać, wypełniać formularze i ewaluować JS. Możesz podzielić panel przeglądarki obok terminala i pozwolić Claude Code bezpośrednio komunikować się z Twoim serwerem deweloperskim.

Wszystko jest skryptowalne przez CLI i socket API — tworzenie przestrzeni roboczych/kart, dzielenie paneli, wysyłanie naciśnięć klawiszy, otwieranie URL-ów w przeglądarce.

## The Zen of cmux

cmux nie narzuca programistom sposobu korzystania z narzędzi. To terminal i przeglądarka z CLI, a reszta zależy od Ciebie.

cmux jest prymitywem, nie rozwiązaniem. Daje Ci terminal, przeglądarkę, powiadomienia, przestrzenie robocze, podziały, karty i CLI do kontrolowania tego wszystkiego. cmux nie zmusza Cię do określonego sposobu korzystania z agentów kodowania. To, co zbudujesz z tych prymitywów, jest Twoje.

Najlepsi programiści zawsze budowali własne narzędzia. Nikt jeszcze nie wymyślił najlepszego sposobu pracy z agentami, a zespoły budujące zamknięte produkty też tego nie odkryły. Programiści najbliżej swoich własnych baz kodu wymyślą to pierwsi.

Daj milionowi programistów kompozycyjne prymitywy, a wspólnie znajdą najefektywniejsze przepływy pracy szybciej, niż jakikolwiek zespół produktowy mógłby zaprojektować odgórnie.

## Dokumentacja

Więcej informacji o konfiguracji cmux znajdziesz w [naszej dokumentacji](https://cmux.com/docs/getting-started?utm_source=readme).

## Skróty Klawiszowe

### Przestrzenie robocze

| Skrót | Akcja |
|----------|--------|
| ⌘ N | Nowa przestrzeń robocza |
| ⌘ 1–8 | Przejdź do przestrzeni roboczej 1–8 |
| ⌘ 9 | Przejdź do ostatniej przestrzeni roboczej |
| ⌃ ⌘ ] | Następna przestrzeń robocza |
| ⌃ ⌘ [ | Poprzednia przestrzeń robocza |
| ⌘ ⇧ W | Zamknij przestrzeń roboczą |
| ⌘ ⇧ R | Zmień nazwę przestrzeni roboczej |
| ⌥ ⌘ E | Edytuj opis przestrzeni roboczej |
| ⌘ B | Przełącz pasek boczny |
| ⌥ ⌘ B | Przełącz prawy pasek boczny |
| ⌘ ⇧ E | Przełącz fokus prawego paska bocznego |

### Powierzchnie

| Skrót | Akcja |
|----------|--------|
| ⌘ T | Nowa powierzchnia |
| ⌘ ⇧ ] | Następna powierzchnia |
| ⌘ ⇧ [ | Poprzednia powierzchnia |
| ⌃ Tab | Następna powierzchnia |
| ⌃ ⇧ Tab | Poprzednia powierzchnia |
| ⌃ 1–8 | Przejdź do powierzchni 1–8 |
| ⌃ 9 | Przejdź do ostatniej powierzchni |
| ⌘ W | Zamknij powierzchnię |

### Podzielone Panele

| Skrót | Akcja |
|----------|--------|
| ⌘ D | Podziel w prawo |
| ⌘ ⇧ D | Podziel w dół |
| ⌥ ⌘ ← → ↑ ↓ | Fokus panelu kierunkowo |
| ⌘ ⇧ H | Mignij fokusowanym panelem |

### Przeglądarka

Skróty narzędzi deweloperskich przeglądarki odpowiadają domyślnym ustawieniom Safari i można je dostosować w `Ustawienia → Skróty klawiszowe`.
Skróty nawigacji w palecie poleceń, w tym ⌃ P, również można dostosować i wyczyścić, aby naciśnięcie klawisza dotarło do aktywnego terminala.

| Skrót | Akcja |
|----------|--------|
| ⌘ ⇧ L | Otwórz przeglądarkę w podziale |
| ⌘ L | Fokus na pasku adresu |
| ⌘ [ | Wstecz |
| ⌘ ] | Do przodu |
| ⌘ R | Przeładuj stronę |
| ⌥ ⌘ I | Przełącz Narzędzia Deweloperskie (domyślne Safari) |
| ⌥ ⌘ C | Pokaż Konsolę JavaScript (domyślne Safari) |

### Powiadomienia

| Skrót | Akcja |
|----------|--------|
| ⌘ I | Pokaż panel powiadomień |
| ⌘ ⇧ U | Przejdź do najnowszego nieprzeczytanego |
| ⌥ ⌘ U | Przełącz stan przeczytania bieżącego elementu |
| ⌃ ⌘ U | Oznacz bieżący element jako najstarszy nieprzeczytany i przejdź do następnego najnowszego nieprzeczytanego |

### Szukaj

| Skrót | Akcja |
|----------|--------|
| ⌘ F | Szukaj |
| ⌘ ⇧ F | Szukaj w katalogu |
| ⌘ G / ⌥ ⌘ G | Znajdź następny / poprzedni |
| ⌥ ⌘ ⇧ F | Ukryj pasek wyszukiwania |
| ⌘ E | Użyj zaznaczenia do wyszukiwania |

### Terminal

| Skrót | Akcja |
|----------|--------|
| ⌘ K | Wyczyść scrollback |
| ⌘ C | Kopiuj (z zaznaczeniem) |
| ⌘ V | Wklej |
| ⌘ + / ⌘ - | Zwiększ / zmniejsz rozmiar czcionki |
| ⌘ 0 | Resetuj rozmiar czcionki |

### Okno

| Skrót | Akcja |
|----------|--------|
| ⌘ ⇧ N | Nowe okno |
| ⌘ ⇧ O | Ponownie otwórz poprzednią sesję |
| ⌘ , | Ustawienia |
| ⌘ ⇧ , | Przeładuj konfigurację |
| ⌘ Q | Zakończ |

## Wersje Nightly

[Pobierz cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY to osobna aplikacja z własnym identyfikatorem pakietu, więc działa obok wersji stabilnej. Budowana automatycznie z najnowszego commitu `main` i aktualizuje się automatycznie przez własny kanał Sparkle.

Zgłaszaj błędy wersji nightly w [GitHub Issues](https://github.com/manaflow-ai/cmux/issues) lub na [#nightly-bugs na Discordzie](https://discord.gg/xsgFEVrWCZ).

## Przywracanie sesji

Po zamknięciu cmux zapisuje bieżącą sesję. Po ponownym uruchomieniu cmux przywraca stan należący do aplikacji:
- Układ okien/przestrzeni roboczych/paneli
- Katalogi robocze
- Scrollback terminala (najlepsza próba)
- URL przeglądarki i historia nawigacji

cmux nie tworzy checkpointów dowolnego stanu działających procesów. tmux, vim, powłoki i nieobsługiwane aplikacje terminalowe otwierają się ponownie jako zwykłe terminale.

Obsługiwane sesje agentów mogą zostać wznowione, gdy hooks zapiszą natywny ID sesji. Zainstaluj hooks po zainstalowaniu CLI agenta, aby jego plik binarny znalazł się w `PATH`:

```bash
cmux hooks setup
cmux hooks setup codex
cmux hooks setup --agent opencode
```

`cmux hooks setup` instaluje obsługiwanych agentów, których może znaleźć, i wypisuje podsumowanie dla pominiętych agentów. Obsługiwane integracje wznawiania obejmują Claude Code, Codex, Grok, OpenCode, Pi, Amp, Cursor CLI, Gemini, Rovo Dev, Copilot, CodeBuddy, Factory i Qoder. Claude Code jest obsługiwany przez wrapper Claude cmux, gdy integracja Claude jest włączona w Ustawieniach.

Zaawansowani użytkownicy i integracje mogą przypiąć własne polecenie wznowienia do bieżącej terminal surface. Przydaje się to narzędziom z własnym trwałym stanem, takim jak sesje tmux lub niestandardowe agent CLI:

```bash
cmux surface resume set --kind tmux --checkpoint work --shell "tmux attach -t work"
cmux surface resume show --json
cmux surface resume clear --checkpoint work
```

Binding pozostaje powiązany z cmux surface. Bindingi utworzone przez publiczny CLI lub socket są zapisywane do inspekcji i ręcznego wznowienia, chyba że zatwierdzisz podpisany prefiks polecenia do automatycznego wznawiania. Zatwierdzone prefiksy są również powiązane z katalogiem roboczym i dokładnymi wartościami środowiska, gdy są obecne. Przeglądaj lub edytuj zatwierdzenia w **Ustawienia > Terminal > Resume Commands**. cmux automatycznie uruchamia tylko bindingi wznowienia oznaczone jako zaufane, na przykład bindingi tmux wykryte z działających procesów lub prefiksy zatwierdzone przez użytkownika. Wrażliwe klucze środowiska, takie jak tokeny, hasła, sekrety i klucze API, są odrzucane przed zapisaniem bindingu wznowienia.

Aby przywrócone terminale agentów pozostawały bezczynne zamiast automatycznie uruchamiać swoje polecenia wznowienia, wyłącz **Ustawienia > Terminal > Resume Agent Sessions on Reopen** lub ustaw to w `~/.config/cmux/cmux.json`:

```json
{
  "terminal": {
    "autoResumeAgentSessions": false
  }
}
```

To wyłącza tylko automatyczne polecenia wznowienia agentów. cmux nadal przywraca zapisany układ, katalogi robocze, scrollback i historię przeglądarki.

Jeśli chcesz ręcznie ponownie zastosować ostatnią zapisaną migawkę, użyj:
- `File > Reopen Previous Session`
- `⌘ ⇧ O`
- `cmux restore-session`

Pod maską cmux zapisuje wersjonowaną migawkę w `~/Library/Application Support/cmux/`, a hooks agentów zapisują mapowania sesji w `~/.cmuxterm/`. Przy przywracaniu cmux najpierw odbudowuje układ, a następnie uruchamia natywne polecenie wznowienia obsługiwanego agenta, gdy automatyczne wznawianie agentów jest włączone.

Przeczytaj pełny przewodnik na <https://cmux.com/docs/session-restore>.

## FAQ

### Jak cmux ma się do Ghostty?

cmux nie jest forkiem Ghostty. Używa [libghostty](https://github.com/ghostty-org/ghostty) jako biblioteki do renderowania terminala, tak samo jak aplikacje używają WebKit do widoków internetowych. Ghostty to samodzielny terminal; cmux to inna aplikacja zbudowana na jego silniku renderowania.

### Jakie platformy są obsługiwane?

Na razie tylko macOS. cmux to natywna aplikacja Swift + AppKit.

### Czy jest aplikacja na iOS?

Tak, w wersji beta. Sparuj iPhone'a z Makiem z okna Mobile Connect i podłącz się do terminali z telefonu, z opcjonalnym przekazywaniem powiadomień terminala. Jest dostępna w TestFlight jako cmux BETA. Zobacz [dokumentację iOS](https://cmux.com/docs/ios).

### Z jakimi agentami kodowania współpracuje cmux?

Ze wszystkimi. cmux to terminal, więc każdy agent działający w terminalu działa od razu: Claude Code, Codex, OpenCode, Gemini CLI, Kiro, Aider, Goose, Amp, Cline, Cursor Agent i wszystko inne, co możesz uruchomić z wiersza poleceń.

### Czy cmux może orkiestrować wielu agentów i subagentów?

Tak. Gdy agent tworzy subagentów lub współpracowników, cmux zamienia ich w natywne panele i podziały zamiast ukrytych procesów w tle. Obsługuje [Claude Code teams](https://cmux.com/docs/agent-integrations/claude-code-teams) i orkiestrację wielu modeli [oh-my-opencode](https://cmux.com/docs/agent-integrations/oh-my-opencode), więc każdy agent w uruchomieniu jest widoczny i kontrolowalny.

### Czy mogę używać cmux ze zdalnymi maszynami?

Tak. Otwieraj przestrzenie robocze przez SSH i podłączaj się do zdalnych sesji tmux, aby agenci mogli działać na zdalnym hoście, podczas gdy Ty sterujesz nimi z cmux. Zobacz [SSH i zdalne](https://cmux.com/docs/ssh).

### Jak działają powiadomienia?

Gdy proces wymaga uwagi, cmux pokazuje pierścienie powiadomień wokół paneli, znaczniki nieprzeczytanych w pasku bocznym, popover powiadomień i powiadomienie pulpitu macOS. Są one wyzwalane automatycznie przez standardowe sekwencje ucieczki terminala (OSC 9/99/777) lub możesz je wyzwolić za pomocą [cmux CLI](https://cmux.com/docs/notifications#cli-usage) i [hooków agentów](https://cmux.com/docs/notifications#integration-examples). Działa każdy agent obsługujący hooki lub OSC, w tym Claude Code, Codex, OpenCode i pi.

### Czy cmux jest programowalny?

Tak. Każda akcja jest dostępna przez cmux CLI i gniazdo Unix: tworzenie przestrzeni roboczych, otwieranie podzielonych paneli, wysyłanie danych wejściowych, odczyt zawartości ekranu, wykonywanie zrzutów ekranu i sterowanie wbudowaną przeglądarką. Zobacz [referencję CLI](https://cmux.com/docs/api) i dokumentację [automatyzacji przeglądarki](https://cmux.com/docs/browser-automation).

### Co potrafi wbudowana przeglądarka?

cmux może podzielić prawdziwy panel przeglądarki obok terminala i jest w pełni programowalny: nawiguj, wykonuj migawki DOM, klikaj, pisz, ewaluuj JavaScript oraz odczytuj aktywność konsoli i sieci przez to samo socket API. Agenci używają go do weryfikacji własnych zmian webowych bez opuszczania cmux. Zobacz [automatyzację przeglądarki](https://cmux.com/docs/browser-automation).

### Czy cmux ma skills?

Tak. Skills to wielokrotnego użytku przepływy pracy, które możesz dać dowolnemu agentowi działającemu w cmux, do rzeczy takich jak sterowanie CLI, automatyzacja przestrzeni roboczych, ustawienia i powierzchnie przeglądarki. Przeglądaj otwartą kolekcję na [cmux-skills](https://github.com/manaflow-ai/cmux-skills) lub przeczytaj [dokumentację skills](https://cmux.com/docs/skills).

### Czy mogę dostosować skróty klawiszowe?

Skróty klawiszowe terminala są odczytywane z pliku konfiguracyjnego Ghostty (`~/.config/ghostty/config`). Skróty specyficzne dla cmux (przestrzenie robocze, podziały, przeglądarka, powiadomienia) można dostosować w Ustawieniach. Zobacz [domyślne skróty](https://cmux.com/docs/keyboard-shortcuts), aby uzyskać pełną listę.

### Czy mogę dostosować cmux?

Tak. Renderowanie terminala używa Twojej konfiguracji Ghostty, więc motywy, czcionki, kolory i kursor przenoszą się bezpośrednio. Własne ustawienia cmux w `~/.config/cmux/cmux.json` kontrolują pasek boczny, pasek kart, podzielone panele i zachowanie, a każdy [skrót klawiszowy](https://cmux.com/docs/keyboard-shortcuts) można edytować. Zobacz [konfigurację](https://cmux.com/docs/configuration).

### Czy moje sesje są zapisywane?

Tak. cmux przywraca Twoje okna, przestrzenie robocze, panele, katalogi robocze i scrollback po ponownym uruchomieniu, a stan przetrwa pełny restart komputera, nie tylko zamknięcie aplikacji. Sesje agentów takich jak Claude Code, Codex i OpenCode również wracają. Zobacz [przywracanie sesji](https://cmux.com/docs/session-restore).

### Jak wypada w porównaniu z tmux?

tmux to multiplekser terminala, który działa wewnątrz dowolnego terminala. cmux to natywna aplikacja macOS z GUI: pionowe karty, podzielone panele, wbudowana przeglądarka i socket API, wszystko wbudowane, bez potrzeby plików konfiguracyjnych ani klawiszy prefiksu. To powiedziawszy, wiele osób chętnie używa cmux razem z SSH i tmux, a cmux może natywnie podłączać się do Twoich zdalnych sesji tmux ([beta](https://cmux.com/docs/remote-tmux)).

### Czy cmux jest darmowy?

Tak, cmux jest darmowy w użyciu. Kod źródłowy jest dostępny na [GitHub](https://github.com/manaflow-ai/cmux).

### Jak mogę wesprzeć cmux?

cmux jest darmowy i open source, i zawsze taki będzie. Jeśli chcesz wesprzeć rozwój i uzyskać wczesny dostęp do tego, co nadchodzi, w tym cmux AI, aplikacji iOS i Cloud VMs, sprawdź [cmux Founders Edition](https://github.com/manaflow-ai/cmux#founders-edition).

### Mam prośbę o funkcję lub znalazłem błąd?

Chcemy o tym usłyszeć. Otwórz [issue](https://github.com/manaflow-ai/cmux/issues) lub [pull request](https://github.com/manaflow-ai/cmux/pulls) na GitHub, albo [napisz do nas](mailto:founders@manaflow.com?subject=cmux%20feature%20request).

## Historia Gwiazdek

<a href="https://star-history.com/#manaflow-ai/cmux&Date">
 <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date&theme=dark" />
   <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" />
   <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=manaflow-ai/cmux&type=Date" width="600" />
 </picture>
</a>

## Współtworzenie

Sposoby zaangażowania się:

- Obserwuj nas na X po aktualizacje [@manaflowai](https://x.com/manaflowai), [@lawrencecchen](https://x.com/lawrencecchen) i [@austinywang](https://x.com/austinywang)
- Dołącz do rozmowy na [Discordzie](https://discord.gg/xsgFEVrWCZ)
- Twórz i uczestniczaj w [zgłoszeniach GitHub](https://github.com/manaflow-ai/cmux/issues) i [dyskusjach](https://github.com/manaflow-ai/cmux/discussions)
- Daj nam znać, co budujesz z cmux

## Społeczność

- [Discord](https://discord.gg/xsgFEVrWCZ)
- [GitHub](https://github.com/manaflow-ai/cmux)
- [X / Twitter](https://twitter.com/manaflowai)
- [YouTube](https://www.youtube.com/channel/UCAa89_j-TWkrXfk9A3CbASw)
- [LinkedIn](https://www.linkedin.com/company/manaflow-ai/)
- [Reddit](https://www.reddit.com/r/cmux/)

## Edycja Założycielska

cmux jest darmowy, open source i zawsze taki będzie. Jeśli chcesz wesprzeć rozwój i uzyskać wczesny dostęp do nadchodzących funkcji:

**[Zdobądź Edycję Założycielską](https://buy.stripe.com/3cI00j2Ld0it5OU33r5EY0q)**

- **Priorytetowe prośby o funkcje/poprawki błędów**
- **Wczesny dostęp: cmux AI, które daje Ci kontekst każdej przestrzeni roboczej, karty i panelu**
- **Wczesny dostęp: aplikacja iOS z terminalami synchronizowanymi między komputerem a telefonem**
- **Wczesny dostęp: maszyny wirtualne w chmurze**
- **Wczesny dostęp: tryb głosowy**
- **Mój osobisty iMessage/WhatsApp**

## Licencja

cmux jest oprogramowaniem open source na licencji [GPL-3.0-or-later](LICENSE).

Jeśli Twoja organizacja nie może spełnić wymogów GPL, dostępna jest licencja komercyjna. Skontaktuj się pod adresem [founders@manaflow.com](mailto:founders@manaflow.com), aby uzyskać szczegóły.
