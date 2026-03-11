> To tłumaczenie zostało wygenerowane przez Claude. Jeśli masz sugestie dotyczące poprawek, otwórz PR.

<h1 align="center">cmux</h1>
<p align="center">Terminal macOS oparty na Ghostty z pionowymi kartami i powiadomieniami dla agentów kodowania AI</p>

<p align="center">
  <a href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg">
    <img src="./docs/assets/macos-badge.png" alt="Pobierz cmux dla macOS" width="180" />
  </a>
</p>

<p align="center">
  <a href="README.md">English</a> | <a href="README.zh-CN.md">简体中文</a> | <a href="README.zh-TW.md">繁體中文</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.es.md">Español</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.da.md">Dansk</a> | <a href="README.ja.md">日本語</a> | Polski | <a href="README.ru.md">Русский</a> | <a href="README.bs.md">Bosanski</a> | <a href="README.ar.md">العربية</a> | <a href="README.no.md">Norsk</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.th.md">ไทย</a> | <a href="README.tr.md">Türkçe</a>
</p>

<p align="center">
  <a href="https://x.com/manaflowai"><img src="https://img.shields.io/badge/@manaflow-555?logo=x" alt="X / Twitter" /></a>
  <a href="https://discord.gg/xsgFEVrWCZ"><img src="https://img.shields.io/badge/Discord-555?logo=discord" alt="Discord" /></a>
</p>

<p align="center">
  <img src="./docs/assets/main-first-image.png" alt="Zrzut ekranu cmux" width="900" />
</p>

<p align="center">
  <a href="https://www.youtube.com/watch?v=i-WxO5YUTOs">▶ Film demonstracyjny</a> · <a href="https://cmux.dev/blog/zen-of-cmux">The Zen of cmux</a>
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
</table>

- **Skryptowalny** — CLI i socket API do tworzenia przestrzeni roboczych, dzielenia paneli, wysyłania naciśnięć klawiszy i automatyzacji przeglądarki
- **Natywna aplikacja macOS** — Zbudowana w Swift i AppKit, nie Electron. Szybki start, niskie zużycie pamięci.
- **Kompatybilny z Ghostty** — Odczytuje istniejącą konfigurację `~/.config/ghostty/config` dla motywów, czcionek i kolorów
- **Akceleracja GPU** — Napędzany przez libghostty dla płynnego renderowania

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

Więcej informacji o konfiguracji cmux znajdziesz w [naszej dokumentacji](https://cmux.dev/docs/getting-started?utm_source=readme).

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
| ⌘ B | Przełącz pasek boczny |

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

### Szukaj

| Skrót | Akcja |
|----------|--------|
| ⌘ F | Szukaj |
| ⌘ G / ⌘ ⇧ G | Znajdź następny / poprzedni |
| ⌘ ⇧ F | Ukryj pasek wyszukiwania |
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
| ⌘ , | Ustawienia |
| ⌘ ⇧ , | Przeładuj konfigurację |
| ⌘ Q | Zakończ |

## Wersje Nightly

[Pobierz cmux NIGHTLY](https://github.com/manaflow-ai/cmux/releases/download/nightly/cmux-nightly-macos.dmg)

cmux NIGHTLY to osobna aplikacja z własnym identyfikatorem pakietu, więc działa obok wersji stabilnej. Budowana automatycznie z najnowszego commitu `main` i aktualizuje się automatycznie przez własny kanał Sparkle.

## Przywracanie sesji (obecne zachowanie)

Przy ponownym uruchomieniu cmux obecnie przywraca tylko układ aplikacji i metadane:
- Układ okien/przestrzeni roboczych/paneli
- Katalogi robocze
- Scrollback terminala (najlepsza próba)
- URL przeglądarki i historia nawigacji

cmux **nie** przywraca stanu żywych procesów wewnątrz aplikacji terminalowych. Na przykład aktywne sesje Claude Code/tmux/vim nie są jeszcze wznawiane po restarcie.

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

Ten projekt jest licencjonowany na warunkach GNU Affero General Public License v3.0 lub nowszej (`AGPL-3.0-or-later`).

Pełny tekst znajduje się w pliku `LICENSE`.
