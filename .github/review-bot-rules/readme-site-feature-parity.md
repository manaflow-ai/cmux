# README and Site Feature Parity

Keep the user-facing feature claims in `README.md` consistent with the marketing site's feature list and FAQ. The README "## Features" section and the homepage feature list (`home.feature.*` in `web/messages/en.json`, rendered by `web/app/[locale]/page.tsx`) describe the same product, so a feature must not be named or described one way on one surface and contradicted on the other. The README is allowed to be the more detailed superset; the homepage and FAQ are a curated subset.

Report a failure when a diff:

- Renames or relabels a shared feature on one surface without matching the other (for example the README says "Scriptable" while the homepage feature is "Programmable", or vice versa).
- Changes a feature's factual claim on one surface so it contradicts the other (platform support, price/free, license, supported agents, networking model, what is built in vs optional).
- Adds a headline feature to the homepage feature list that directly conflicts with how the README presents the product, or removes a feature from one surface in a way that leaves the two materially inconsistent, without updating the other or stating why.
- Changes a homepage FAQ answer (`home.faq*` in `web/messages/en.json`) so it contradicts a claim in `README.md` (for example FAQ says cmux is free while the README implies otherwise, or the FAQ describes a capability the README denies).

Expected shape:

- When a shared feature's name or factual claim changes on one surface, the same change lands on the other surface in the same PR, or the PR explains why they intentionally differ.
- The README may keep extra features (for example SSH, Claude Code Teams, Custom commands, Browser import) that the curated homepage omits, as long as the features both surfaces do mention use consistent names and non-contradicting claims.
- Wording length and detail may differ between the README and the homepage; only the feature name and the underlying factual claim need to agree.

Allowed cases:

- The README staying a more detailed superset of the homepage feature list.
- Pure description/length differences where the feature name and factual claim still agree.
- Localization-only changes that translate existing copy without changing the English source meaning.
- Doc, blog, or changelog copy that is not a headline feature claim.
- Existing inconsistencies the PR does not introduce or worsen, though mention nearby drift when it is adjacent to the change.

When reporting, name the exact feature or FAQ entry and the specific `README.md` line it conflicts with, state the contradiction, and suggest the smallest fix: align the term or claim, or update the other surface in the same PR.
