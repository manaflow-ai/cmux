"""Shared parsing for Subresource Integrity metadata returned by registries."""

ALGORITHM_STRENGTH = {
    "sha256": 1,
    "sha384": 2,
    "sha512": 3,
}


class SRIError(ValueError):
    """Raised when an SRI list cannot support an integrity decision."""


def strongest_sri_entries(integrity: str) -> tuple[str, frozenset[str]]:
    entries_by_algorithm: dict[str, set[str]] = {}
    entries = integrity.split()
    if not entries:
        raise SRIError("empty integrity metadata")
    for entry in entries:
        algorithm, separator, encoded = entry.partition("-")
        if not separator or not algorithm or not encoded:
            raise SRIError("malformed integrity metadata")
        if algorithm in ALGORITHM_STRENGTH:
            entries_by_algorithm.setdefault(algorithm, set()).add(entry)
    if not entries_by_algorithm:
        raise SRIError("no supported integrity algorithm")
    strongest = max(
        entries_by_algorithm,
        key=ALGORITHM_STRENGTH.__getitem__,
    )
    return strongest, frozenset(entries_by_algorithm[strongest])
