# cmux-next-ios App Store review package

cmux-next-ios ships under the production App Store record and replaces the
classic iPhone app as an update. Everything App Store Connect shows a reviewer or
a customer for it lives here, beside the app it describes.

| Path | What it is | How it reaches App Store Connect |
|---|---|---|
| `review-notes-asc.txt` | App Review notes template | `cmux-next-ios/scripts/asc_review_package.py sync-notes` |
| `metadata/app-info/<locale>.json` | name, subtitle, privacy policy URL | `asc metadata apply --dir cmux-next-ios/AppStoreReview/metadata` |
| `metadata/version/<version>/<locale>.json` | description, keywords, promotional text, marketing and support URLs | the same `asc metadata apply`; `asc_review_package.py sync-listing` then sets and reads back every locale's Support URL |
| `reviewer-setup.md` | the review path, where each live value lives, what must be true before a submission | read by people |

## Script

`cmux-next-ios/scripts/asc_review_package.py` takes every path from its own
location, so a workflow on any branch can check out feat-cmux-next anywhere and
run it:

```
python3 <checkout>/cmux-next-ios/scripts/asc_review_package.py --app "$ASC_APP_ID" sync-notes
python3 <checkout>/cmux-next-ios/scripts/asc_review_package.py --app "$ASC_APP_ID" sync-listing
```

`--version` defaults to `MARKETING_VERSION` in `cmux-next-ios/project.yml`. Both
commands take `--dry-run`. Environment:

- App Store Connect key: `ASC_API_KEY_ID`, `ASC_API_ISSUER_ID`, and
  `ASC_API_KEY_PATH` or `ASC_API_KEY_P8_BASE64` (or the INTERNAL builder's
  `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_PRIVATE_KEY_PATH`).
- `CMUX_IOS_REVIEW_CHIEF_NAME`: the demo account's Cloud Chief, from the
  `IOS_APPSTORE_REVIEW_CHIEF_NAME` repository variable. `sync-notes` stops before
  writing anything while it, or any App Store Connect field the notes use, is
  empty.

## Locales and version

The listing covers the 14 locales of the production record: de-DE, en-US, es-ES,
fr-FR, it, ja, ko, nl-NL, pl, pt-BR, ru, tr, zh-Hans, zh-Hant. `asc metadata
apply --allow-deletes` deletes a locale that is missing here.

`metadata/version/` holds one directory, named for `MARKETING_VERSION`. When
that version changes, rename the directory in the same change;
`tests/test_ios_appstore_listing_text.py` fails until it matches.

## Rules the tests hold

`tests/test_ios_appstore_listing_text.py` and `tests/test_asc_review_package.py`
run in `cmux-next-guards.yml`. They fail when:

- a field is over its App Store limit, or a locale is missing from either tree;
- any locale names a classic-only screen (Connection Method, Add Computer and the
  like);
- the public listing carries review instructions (those go in the notes);
- the listing or the notes quote a label the release app does not show (strings
  in `#if DEBUG` code, mock data, demos and the gallery do not count);
- the notes leave out a permission `project.yml` declares;
- the review demo steps spot in the notes is not marked, or its markers would
  reach a reviewer.

The app has string catalogs for de, es, fr, ja, ko, zh-Hans and zh-Hant, and most
screen names are not in them yet, so screens show in English on every device.
The translated listings describe features, not exact screen names, and the it,
nl-NL, pl, pt-BR, ru and tr listings say the app is in English.
