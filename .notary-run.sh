( if git config -f .gitmodules --get submodule.ghostty-next.path >/dev/null; then
  git submodule update --init --depth 1 ghostty-next
fi ) > /tmp/o.txt 2>&1 && echo 'PASS Initialize ghostty-next for the toolchain notices' || { echo 'FAILED Initialize ghostty-next for the toolchain notices'; tail -15 /tmp/o.txt; }
( python3 scripts/whats-new/test_digest.py
python3 scripts/whats-new/test_validate.py
python3 scripts/whats-new/test_community.py
python3 tests/test_cmux_next_release_notes.py
python3 tests/test_release_notes_pr_media.py
python3 tests/test_release_notes_clips.py
python3 tests/test_whats_new_clips.py
python3 scripts/cmux-next/media/whats-new-clips.py check ) > /tmp/o.txt 2>&1 && echo 'PASS Test Whats New highlights and release notes' || { echo 'FAILED Test Whats New highlights and release notes'; tail -15 /tmp/o.txt; }
( ./tests/test_ci_create_dmg_pinned.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate create-dmg version pinning' || { echo 'FAILED Validate create-dmg version pinning'; tail -15 /tmp/o.txt; }
( ./tests/test_ci_release_dmg_lzma.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate release DMG LZMA encoding' || { echo 'FAILED Validate release DMG LZMA encoding'; tail -15 /tmp/o.txt; }
( python3 tests/test_compose_stable_appcast.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the stable appcast composer' || { echo 'FAILED Validate the stable appcast composer'; tail -15 /tmp/o.txt; }
( ./tests/test_ci_homebrew_cask_macos_dependency.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate Homebrew cask macOS dependency syntax' || { echo 'FAILED Validate Homebrew cask macOS dependency syntax'; tail -15 /tmp/o.txt; }
( ./tests/test_app_bundle_license_compliance.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate app bundle license compliance' || { echo 'FAILED Validate app bundle license compliance'; tail -15 /tmp/o.txt; }
( python3 tests/test_verify_app_libintl.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate shipped libintl check' || { echo 'FAILED Validate shipped libintl check'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_tui_owner_wait_defers.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the cmux-tui tree owner check' || { echo 'FAILED Validate the cmux-tui tree owner check'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_tui_pin_duplicate_skip.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the cmux-tui pin duplicate skip' || { echo 'FAILED Validate the cmux-tui pin duplicate skip'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_tui_lane_daemon_tests.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate lane-branch cmux-tui publishes without the daemon tests' || { echo 'FAILED Validate lane-branch cmux-tui publishes without the daemon tests'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_tui_point_channel.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the feat-cmux-next channel pointer only moves forward' || { echo 'FAILED Validate the feat-cmux-next channel pointer only moves forward'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_tui_superseded_push.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate superseded cmux-tui pushes skip their builds and daemon tests' || { echo 'FAILED Validate superseded cmux-tui pushes skip their builds and daemon tests'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_delivery_concurrency.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly builds and signers never cancel or replace a waiting run' || { echo 'FAILED Validate nightly builds and signers never cancel or replace a waiting run'; tail -15 /tmp/o.txt; }
( python3 tests/test_gh_budget_wait.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly publish-path gh calls wait through a rate limit' || { echo 'FAILED Validate nightly publish-path gh calls wait through a rate limit'; tail -15 /tmp/o.txt; }
( python3 tests/test_download_run_artifact_retries.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the run artifact download waits through a refused GitHub call' || { echo 'FAILED Validate the run artifact download waits through a refused GitHub call'; tail -15 /tmp/o.txt; }
( python3 tests/test_gh_app_token.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate publish gh calls go out as the release App first, github.token as fallback' || { echo 'FAILED Validate publish gh calls go out as the release App first, github.token as fallback'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_tui_publisher_testing.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate a feat-cmux-next push stops deferring to a publisher whose daemon tests are stuck' || { echo 'FAILED Validate a feat-cmux-next push stops deferring to a publisher whose daemon tests are stuck'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_next_media_tour_gate.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate when the cmux-next tour runs (merges, dispatches, adding media-tour)' || { echo 'FAILED Validate when the cmux-next tour runs (merges, dispatches, adding media-tour)'; tail -15 /tmp/o.txt; }
( python3 tests/test_media_auto_tour.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate that a pull request tours once, when media-tour is added' || { echo 'FAILED Validate that a pull request tours once, when media-tour is added'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_next_media_path_map.py
python3 tests/test_cmux_next_media_runner_scope.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate webview-only changes tour on Linux, not a Mac' || { echo 'FAILED Validate webview-only changes tour on Linux, not a Mac'; tail -15 /tmp/o.txt; }
( python3 tests/test_ci_prune_media_derived_data.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the cmux-next tour bounds its DerivedData on each Mac' || { echo 'FAILED Validate the cmux-next tour bounds its DerivedData on each Mac'; tail -15 /tmp/o.txt; }
( python3 tests/test_tour_requirements.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate reload.sh reads the cmux-next tours free-space floor from tour-requirements.json' || { echo 'FAILED Validate reload.sh reads the cmux-next tours free-space floor from tour-requirements.json'; tail -15 /tmp/o.txt; }
( python3 tests/test_media_tag_lock.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate a second cmux-next tour of a tag waits for the tour holding it' || { echo 'FAILED Validate a second cmux-next tour of a tag waits for the tour holding it'; tail -15 /tmp/o.txt; }
( python3 tests/test_ci_media_module_cache_stamp.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the cmux-next tour drops stale prebuilt modules when a binary pin changes' || { echo 'FAILED Validate the cmux-next tour drops stale prebuilt modules when a binary pin changes'; tail -15 /tmp/o.txt; }
( python3 tests/test_media_app_cache.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the cmux-next tour reuses a base app another tour built for the same commit' || { echo 'FAILED Validate the cmux-next tour reuses a base app another tour built for the same commit'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_next_media_tree_fallback.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the cmux-next tour never waits for an unpublished base cmux-tui tree' || { echo 'FAILED Validate the cmux-next tour never waits for an unpublished base cmux-tui tree'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_tui_feat_publish_order.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate feat-cmux-next publishes its cmux-tui tree before the daemon tests' || { echo 'FAILED Validate feat-cmux-next publishes its cmux-tui tree before the daemon tests'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_tui_publish_retries.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate cmux-tui publication retries a rate-limited attestation and a slow fetch' || { echo 'FAILED Validate cmux-tui publication retries a rate-limited attestation and a slow fetch'; tail -15 /tmp/o.txt; }
( python3 tests/test_update_release_tag.py
python3 tests/test_nightly_next_computer_use_helper.py
python3 tests/test_nightly_next_post_publish.py
python3 tests/test_nightly_publication_marker.py
python3 tests/test_nightly_republish_delta_guard.py
python3 tests/test_nightly_resume_tracks.py
python3 tests/test_nightly_signed_unnotarized_artifact.py
python3 tests/test_nightly_background_steps.py
python3 tests/test_nightly_notices_submodule.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly API tag finalization' || { echo 'FAILED Validate nightly API tag finalization'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_next_dev_daily_dispatch.py
python3 tests/test_cmux_next_dev_kick.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the cmux NEXT DEV daily dispatcher' || { echo 'FAILED Validate the cmux NEXT DEV daily dispatcher'; tail -15 /tmp/o.txt; }
( bash ./tests/test_nightly_tag_permission_probe.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly tag permission probe' || { echo 'FAILED Validate nightly tag permission probe'; tail -15 /tmp/o.txt; }
( ./tests/test_ci_nightly_xcode_selection.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly Xcode selection' || { echo 'FAILED Validate nightly Xcode selection'; tail -15 /tmp/o.txt; }
( ./tests/test_ci_xcode_selection_fast_path.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate CI Xcode selection fast path' || { echo 'FAILED Validate CI Xcode selection fast path'; tail -15 /tmp/o.txt; }
( python3 tests/test_github_release_publication.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate resumable GitHub release publication' || { echo 'FAILED Validate resumable GitHub release publication'; tail -15 /tmp/o.txt; }
( python3 tests/test_release_homebrew_gate.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the Homebrew cask update gate' || { echo 'FAILED Validate the Homebrew cask update gate'; tail -15 /tmp/o.txt; }
( python3 tests/test_ci_production_secrets_protected_env.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate production-secret jobs run only in the protected release environment' || { echo 'FAILED Validate production-secret jobs run only in the protected release environment'; tail -15 /tmp/o.txt; }
( python3 tests/test_ci_homebrew_untrusted_input.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the Homebrew cask update keeps run metadata out of scripts' || { echo 'FAILED Validate the Homebrew cask update keeps run metadata out of scripts'; tail -15 /tmp/o.txt; }
( ./tests/test_ci_universal_release_settings.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate universal GhosttyKit and Release build settings' || { echo 'FAILED Validate universal GhosttyKit and Release build settings'; tail -15 /tmp/o.txt; }
( bash ./tests/test_nightly_universal_build.sh
python3 tests/test_nightly_trusted_routing.py
python3 tests/test_nightly_build_state.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate universal nightly workflow' || { echo 'FAILED Validate universal nightly workflow'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_step_coverage.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate every nightly step has a pull request counterpart' || { echo 'FAILED Validate every nightly step has a pull request counterpart'; tail -15 /tmp/o.txt; }
( bash tests/test_nightly_next_legacy_tested_digest.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Dry-run the nightlys tested-DMG gate for the old feed' || { echo 'FAILED Dry-run the nightlys tested-DMG gate for the old feed'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_next_guards_route.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate feat-cmux-next runs these release guards' || { echo 'FAILED Validate feat-cmux-next runs these release guards'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_next_checkout_retry.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate cmux-next self-hosted checkouts retry once' || { echo 'FAILED Validate cmux-next self-hosted checkouts retry once'; tail -15 /tmp/o.txt; }
( bash ./tests/test_upload_sentry_dsyms.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly dSYM upload retries and never fails the nightly' || { echo 'FAILED Validate the nightly dSYM upload retries and never fails the nightly'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_release_notes.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly release notes and appcast summaries' || { echo 'FAILED Validate nightly release notes and appcast summaries'; tail -15 /tmp/o.txt; }
( bash ./tests/test_nightly_sparkle_key.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly Sparkle key selection' || { echo 'FAILED Validate nightly Sparkle key selection'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_guard.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly-next guard' || { echo 'FAILED Validate the nightly-next guard'; tail -15 /tmp/o.txt; }
( python3 tests/test_publish_nightly_next_r2.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly-next R2 publisher' || { echo 'FAILED Validate the nightly-next R2 publisher'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_r2_prune.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly-next R2 retention prune' || { echo 'FAILED Validate the nightly-next R2 retention prune'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_feed_rollback.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly-next feed rollback' || { echo 'FAILED Validate the nightly-next feed rollback'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_ring.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly-next release-ring tags' || { echo 'FAILED Validate the nightly-next release-ring tags'; tail -15 /tmp/o.txt; }
( python3 tests/test_edge_feed.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the cmux NEXT Edge feed composer' || { echo 'FAILED Validate the cmux NEXT Edge feed composer'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_canary_mode.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly-next canary mode and its one-week flip' || { echo 'FAILED Validate the nightly-next canary mode and its one-week flip'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_fix_forward.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly-next fix-forward after a pull' || { echo 'FAILED Validate the nightly-next fix-forward after a pull'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_train.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly-next release train, verdicts and G1 tree check' || { echo 'FAILED Validate the nightly-next release train, verdicts and G1 tree check'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_arm64_only.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly-next arm64-only track' || { echo 'FAILED Validate the nightly-next arm64-only track'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_web_bundles_order.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly web bundles build before the Release build' || { echo 'FAILED Validate the nightly web bundles build before the Release build'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_helpers_beside_release_build.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly helper builds beside the Release build' || { echo 'FAILED Validate nightly helper builds beside the Release build'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_release_notes_fetch.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly-next release notes fetch (published span only)' || { echo 'FAILED Validate the nightly-next release notes fetch (published span only)'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_cmux_tui_resolve.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly cmux-tui resolver (newest published tree, no wait)' || { echo 'FAILED Validate the nightly cmux-tui resolver (newest published tree, no wait)'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_source_archive.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the blocking nightly-next source archive' || { echo 'FAILED Validate the blocking nightly-next source archive'; tail -15 /tmp/o.txt; }
( python3 tests/test_cmux_next_guards_notices_pair.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the cmux-next guards notices pair check' || { echo 'FAILED Validate the cmux-next guards notices pair check'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_version.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly version numbers per track' || { echo 'FAILED Validate nightly version numbers per track'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_identity.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly-next ships as cmux NEXT beside classic NIGHTLY' || { echo 'FAILED Validate nightly-next ships as cmux NEXT beside classic NIGHTLY'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_sign_admit.py
python3 tests/test_nightly_sign_shadow_workflow.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly signing admission and its shadow mode' || { echo 'FAILED Validate nightly signing admission and its shadow mode'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_promotion_admission.py
python3 tests/test_nightly_next_promotion_queue.py
python3 tests/test_ci_nightly_push_throttle.py
python3 tests/test_ci_nightly_off_blacksmith.py
python3 tests/test_ci_runs_on_fallback.py
python3 tests/test_ci_helper_prebuild_lifecycle.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly push throttle' || { echo 'FAILED Validate nightly push throttle'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_unsigned_resume.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate unsigned nightly resume provenance and routing' || { echo 'FAILED Validate unsigned nightly resume provenance and routing'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_sign_runner.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly signing jobs take a Blacksmith label with a moving queue' || { echo 'FAILED Validate the nightly signing jobs take a Blacksmith label with a moving queue'; tail -15 /tmp/o.txt; }
( ./tests/test_notarize_nightly_dmg.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly notarization behavior' || { echo 'FAILED Validate nightly notarization behavior'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_notary_handoff.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly-next notarization handoff' || { echo 'FAILED Validate the nightly-next notarization handoff'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_next_recovery.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate the nightly-next pending notarization continuation' || { echo 'FAILED Validate the nightly-next pending notarization continuation'; tail -15 /tmp/o.txt; }
( python3 tests/test_poll_notary_submission.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate asynchronous notarization status polling' || { echo 'FAILED Validate asynchronous notarization status polling'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_notarization_poll_loop.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate notarization polling artifact reuse' || { echo 'FAILED Validate notarization polling artifact reuse'; tail -15 /tmp/o.txt; }
( python3 tests/test_nightly_artifact_alias.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate accepted nightly DMG artifact aliases' || { echo 'FAILED Validate accepted nightly DMG artifact aliases'; tail -15 /tmp/o.txt; }
( ./tests/test_finalize_sparkle_deltas.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate Sparkle delta finalization' || { echo 'FAILED Validate Sparkle delta finalization'; tail -15 /tmp/o.txt; }
( ./tests/test_fetch_previous_nightly_dmgs.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate previous nightly build fetch' || { echo 'FAILED Validate previous nightly build fetch'; tail -15 /tmp/o.txt; }
( ./tests/test_notarize_computer_use_helper.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate Computer Use helper notarization behavior' || { echo 'FAILED Validate Computer Use helper notarization behavior'; tail -15 /tmp/o.txt; }
( node scripts/release_asset_guard.test.js ) > /tmp/o.txt 2>&1 && echo 'PASS Validate release asset guard' || { echo 'FAILED Validate release asset guard'; tail -15 /tmp/o.txt; }
( ./tests/test_ci_release_build_timeout.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate release-build timeout guard' || { echo 'FAILED Validate release-build timeout guard'; tail -15 /tmp/o.txt; }
( ./tests/test_sparkle_build_monotonic_modes.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate Sparkle monotonic guard modes' || { echo 'FAILED Validate Sparkle monotonic guard modes'; tail -15 /tmp/o.txt; }
( ./tests/test_sparkle_generate_appcast_no_deltas.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate Sparkle appcast generation without previous archives' || { echo 'FAILED Validate Sparkle appcast generation without previous archives'; tail -15 /tmp/o.txt; }
( ./tests/test_generate_nightly_deltas.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate nightly Sparkle delta bases and feed' || { echo 'FAILED Validate nightly Sparkle delta bases and feed'; tail -15 /tmp/o.txt; }
( python3 tests/test_appcast_keep_pubdates.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate a rewritten nightly appcast keeps each items first-publish pubDate' || { echo 'FAILED Validate a rewritten nightly appcast keeps each items first-publish pubDate'; tail -15 /tmp/o.txt; }
( ./tests/test_sparkle_generate_keys_permissions.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate Sparkle key export permissions' || { echo 'FAILED Validate Sparkle key export permissions'; tail -15 /tmp/o.txt; }
( python3 tests/test_appcast_minimum_system_version.py ) > /tmp/o.txt 2>&1 && echo 'PASS Validate Sparkle appcast macOS floor' || { echo 'FAILED Validate Sparkle appcast macOS floor'; tail -15 /tmp/o.txt; }
( ./tests/test_compress_markdown_viewer_assets.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate markdown viewer asset compression' || { echo 'FAILED Validate markdown viewer asset compression'; tail -15 /tmp/o.txt; }
( ./tests/test_strip_release_bundle.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate release bundle stripping' || { echo 'FAILED Validate release bundle stripping'; tail -15 /tmp/o.txt; }
( ./tests/test_cmux_tui_ssh_payload_bundle.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate cmux-tui SSH payload thinning and signing' || { echo 'FAILED Validate cmux-tui SSH payload thinning and signing'; tail -15 /tmp/o.txt; }
( ./tests/test_ci_swift_warning_budget.sh ) > /tmp/o.txt 2>&1 && echo 'PASS Validate Swift warning budget guard' || { echo 'FAILED Validate Swift warning budget guard'; tail -15 /tmp/o.txt; }
