extension SSHForegroundAuthenticationRetryPolicy {
    func processIdentityValidationShellFunction() -> String {
        #"""
        cmux_ssh_auth_record_is_current() (
          cmux_expected_pid="$1"
          cmux_expected_parent="$2"
          cmux_expected_group="$3"
          cmux_expected_started="$4"
          /bin/ps -o ppid= -o pgid= -o state= -o lstart= -p "$cmux_expected_pid" 2>/dev/null | (
            IFS=' ' read -r cmux_observed_parent cmux_observed_group cmux_observed_state \
              cmux_observed_weekday cmux_observed_month cmux_observed_day \
              cmux_observed_clock cmux_observed_year || exit 1
            cmux_observed_started="${cmux_observed_weekday}_${cmux_observed_month}_${cmux_observed_day}_${cmux_observed_clock}_${cmux_observed_year}"
            [ "$cmux_observed_parent" = "$cmux_expected_parent" ] &&
              [ "$cmux_observed_group" = "$cmux_expected_group" ] &&
              [ "$cmux_observed_started" = "$cmux_expected_started" ] || exit 1
            case "$cmux_observed_state" in *Z*) exit 1 ;; esac
          )
        )
        """#
    }
}
